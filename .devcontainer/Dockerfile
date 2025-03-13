FROM debian:bookworm-20250224-slim

# git, curl, zip, unzip, jq, tree => for development
# less => for AWSCLI
RUN apt-get update \
    && apt-get install -y \
        git \
        curl \
        zip \
        unzip \
        jq \
        tree \
        less \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# install awscliv2
ARG AWSCLI_VER=2.24.22
RUN curl -sL https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VER}.zip -o awscliv2.zip \
    && unzip -q awscliv2.zip \
    && aws/install

# install terraform
ARG TERA_VER=1.11.1
RUN curl -sL https://releases.hashicorp.com/terraform/${TERA_VER}/terraform_${TERA_VER}_linux_amd64.zip -o terraform.zip \
    && unzip -q ./terraform.zip -d /usr/local/bin/ \
    && rm -f ./terraform.zip

# setting for terraform and terragrunt
RUN echo 'alias tf="terraform"' >> ~/.bashrc

CMD [ "sleep", "infinity" ]
