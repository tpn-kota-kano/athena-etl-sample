locals {
  resource_name_prefix = "athena-etl"

  intermediate_key_athena_result = "athena_results"
  intermediate_key_output        = "outputs"
  intermediate_key_sql           = "sqls"
  intermediate_key_log           = "logs"
}

###############################
# ステートマシン, ステートマシン実行用ロール, ポリシー
###############################
resource "aws_iam_role" "sfn_exec" {
  name = "${local.resource_name_prefix}-sfn-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "states.amazonaws.com"
        },
      },
    ],
  })
}

resource "aws_iam_policy" "sfn_basic" {
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "iam:PassRole",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "states:CreateStateMachine",
          "states:DescribeExecution",
          "states:StopExecution",
        ],
        Effect   = "Allow",
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_policy" "sfn_exec" {
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "s3:*",
          "glue:*",
          "athena:*"
        ],
        Resource = "*",
        Effect   = "Allow"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "sfn_exec_1" {
  role       = aws_iam_role.sfn_exec.name
  policy_arn = aws_iam_policy.sfn_basic.arn
}

resource "aws_iam_role_policy_attachment" "sfn_exec_2" {
  role       = aws_iam_role.sfn_exec.name
  policy_arn = aws_iam_policy.sfn_exec.arn
}

resource "aws_sfn_state_machine" "this" {
  name     = "${local.resource_name_prefix}-state-machine"
  role_arn = aws_iam_role.sfn_exec.arn

  definition = jsonencode({
    "QueryLanguage" : "JSONata",
    "StartAt" : "mock_input",
    "States" : {
      "mock_input" : {
        "Type" : "Pass",
        "Next" : "set_variable",
        "Output" : {
          "ATHENA_BUCKET" : "${aws_s3_bucket.athena.id}",
          "ATHENA_WORKGROUP" : "${aws_athena_workgroup.main.id}",
          "GLUE_DATABASE" : "${aws_glue_catalog_database.simple_logs.name}",
          "INTERMEDIATE_KEY_ATHENA_RESULT" : local.intermediate_key_athena_result,
          "INTERMEDIATE_KEY_OUTPUT" : local.intermediate_key_output,
          "INTERMEDIATE_KEY_SQL" : local.intermediate_key_sql,
        }
      },
      "set_variable" : {
        "Type" : "Pass",
        "Next" : "get_list_sqls",
        "Assign" : {
          "ATHENA_BUCKET" : "{% $states.input.ATHENA_BUCKET %}",
          "ATHENA_WORKGROUP" : "{% $states.input.ATHENA_WORKGROUP %}",
          "GLUE_DATABASE" : "{% $states.input.GLUE_DATABASE %}",
          "INTERMEDIATE_KEY_ATHENA_RESULT" : "{% $states.input.INTERMEDIATE_KEY_ATHENA_RESULT %}",
          "INTERMEDIATE_KEY_OUTPUT" : "{% $states.input.INTERMEDIATE_KEY_OUTPUT %}",
          "INTERMEDIATE_KEY_SQL" : "{% $states.input.INTERMEDIATE_KEY_SQL %}",
        }
      },
      "get_list_sqls" : {
        "Type" : "Task",
        "Resource" : "arn:aws:states:::aws-sdk:s3:listObjectsV2",
        "Arguments" : {
          "Bucket" : "{% $ATHENA_BUCKET %}",
          "Prefix" : "{% $INTERMEDIATE_KEY_SQL %}"
        },
        "Output" : file("./jsonata/list_sql_files.jsonata"),
        "Next" : "Map"
      },
      "Map" : {
        "Type" : "Map",
        "ItemProcessor" : {
          "ProcessorConfig" : {
            "Mode" : "INLINE"
          },
          "StartAt" : "load_sql",
          "States" : {
            "load_sql" : {
              "Type" : "Task",
              "Arguments" : {
                "Bucket" : "{% $ATHENA_BUCKET %}",
                "Key" : "{% $states.input.key %}"
              },
              "Assign" : {
                "SQL_NAME" : "{% $states.input.sql_name %}"
              },
              "Resource" : "arn:aws:states:::aws-sdk:s3:getObject",
              "Next" : "StartQueryExecution",
              "Output" : {
                "SQL" : "{% $states.result.Body %}"
              }
            },
            "StartQueryExecution" : {
              "Arguments" : {
                "QueryExecutionContext" : {
                  "Database" : "{% $GLUE_DATABASE %}"
                },
                "QueryString" : "{% $states.input.SQL %}",
                "ResultConfiguration" : {
                  "OutputLocation" : "{% 's3://' & $ATHENA_BUCKET & '/' & $INTERMEDIATE_KEY_ATHENA_RESULT %}"
                },
                "WorkGroup" : "{% $ATHENA_WORKGROUP %}"
              },
              "Assign" : {
                "QUERY_EXECUTION_ID" : "{% $states.result.QueryExecution.QueryExecutionId %}"
              },
              "Resource" : "arn:aws:states:::athena:startQueryExecution.sync",
              "Type" : "Task",
              "Next" = "copy_athena_result"
            },
            "copy_athena_result" : {
              "Type" : "Task",
              "Arguments" : {
                "Bucket" : "{% $ATHENA_BUCKET %}",
                "CopySource" : "{% $ATHENA_BUCKET & '/' & $INTERMEDIATE_KEY_ATHENA_RESULT & '/' & $QUERY_EXECUTION_ID & '.csv' %}",
                "Key" : "{% $INTERMEDIATE_KEY_OUTPUT & '/' & $SQL_NAME & '/' & $QUERY_EXECUTION_ID & '.csv' %}"
              },
              "Resource" : "arn:aws:states:::aws-sdk:s3:copyObject",
              "Next" : "delete_athena_results"
            },
            "delete_athena_results" : {
              "Type" : "Task",
              "Arguments" : {
                "Bucket" : "{% $ATHENA_BUCKET %}",
                "Delete" : {
                  "Objects" : [
                    {
                      "Key" : "{% $INTERMEDIATE_KEY_ATHENA_RESULT & '/' & $QUERY_EXECUTION_ID & '.csv' %}"
                    },
                    {
                      "Key" : "{% $INTERMEDIATE_KEY_ATHENA_RESULT & '/' & $QUERY_EXECUTION_ID & '.csv.metadata' %}"
                    }
                  ]
                }
              },
              "Resource" : "arn:aws:states:::aws-sdk:s3:deleteObjects",
              "End" : true
            },
          }
        },
        "End" : true
      },
    }
  })
}

###############################
# Athena ワークグループ
###############################
resource "aws_athena_workgroup" "main" {
  name = "${local.resource_name_prefix}-main"

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena.id}/${local.intermediate_key_athena_result}/"
    }
  }

  force_destroy = true
}

###############################
# Athena 用 S3 バケット
###############################
resource "random_string" "bucket_suffix" {
  length  = 16
  special = false
  upper   = false
}

resource "aws_s3_bucket" "athena" {
  bucket        = "${local.resource_name_prefix}-${random_string.bucket_suffix.result}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "athena" {
  bucket = aws_s3_bucket.athena.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "simple_logs" {
  bucket       = aws_s3_bucket.athena.id
  key          = "${local.intermediate_key_log}/simple_logs.csv"
  content      = <<CSV
id,log_timestamp,message
1,2023-10-01T12:00:00Z,Sample log message 1
2,2023-10-01T12:05:00Z,Sample log message 2
3,2023-10-01T12:10:00Z,Sample log message 3
CSV
  content_type = "text/csv"
}

resource "aws_s3_object" "elb_requests_by_hour_sql" {
  bucket       = aws_s3_bucket.athena.bucket
  key          = "${local.intermediate_key_sql}/elb_requests_by_hour.sql"
  content      = <<SQL
SELECT
  date_format(from_iso8601_timestamp(log_timestamp), '%Y-%m-%d %H:00:00') AS hour,
  count(*) AS request_count
FROM "${aws_glue_catalog_database.simple_logs.name}"."${aws_glue_catalog_table.simple_logs.name}"
GROUP BY 1
ORDER BY 1;
SQL
  content_type = "text/sql"
}

resource "aws_s3_object" "log_message_analysis_sql" {
  bucket       = aws_s3_bucket.athena.bucket
  key          = "${local.intermediate_key_sql}/log_message_analysis.sql"
  content      = <<SQL
SELECT
  message,
  count(*) as occurrence_count
FROM "${aws_glue_catalog_database.simple_logs.name}"."${aws_glue_catalog_table.simple_logs.name}"
GROUP BY message
ORDER BY occurrence_count DESC;
SQL
  content_type = "text/sql"
}

###############################
# Athena 用 Glue カタログ
###############################
resource "aws_glue_catalog_database" "simple_logs" {
  name = "${local.resource_name_prefix}-simple-logs-database"
}

resource "aws_glue_catalog_table" "simple_logs" {
  name          = "${local.resource_name_prefix}-simple-logs-table"
  database_name = aws_glue_catalog_database.simple_logs.name
  table_type    = "EXTERNAL_TABLE"
  parameters = {
    "skip.header.line.count" = "1",
    "classification"         = "csv"
  }

  storage_descriptor {
    location          = "s3://${aws_s3_bucket.athena.bucket}/${local.intermediate_key_log}/"
    input_format      = "org.apache.hadoop.mapred.TextInputFormat"
    output_format     = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed        = false
    number_of_buckets = -1

    columns {
      name = "id"
      type = "int"
    }

    columns {
      name = "log_timestamp"
      type = "string"
    }

    columns {
      name = "message"
      type = "string"
    }

    ser_de_info {
      name                  = "simple_logs_serde"
      serialization_library = "org.apache.hadoop.hive.serde2.OpenCSVSerde"
      parameters = {
        "separatorChar" = ",",
        "quoteChar"     = "\""
      }
    }
  }
}
