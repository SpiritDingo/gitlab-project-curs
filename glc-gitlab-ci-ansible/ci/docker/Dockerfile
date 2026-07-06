FROM willhallonline/ansible:2.16-alpine

LABEL maintainer="DevOps Team"
LABEL description="Custom Ansible image for GitLab CI pipelines"

RUN apk add --no-cache \
    openssh-client \
    git \
    py3-pip \
    && pip install --no-cache-dir \
    ansible-lint \
    yamllint

WORKDIR /builds

ENV ANSIBLE_FORCE_COLOR=1 \
    ANSIBLE_HOST_KEY_CHECKING=True \
    ANSIBLE_ROLES_PATH=/builds/roles

COPY ci/scripts/run-ansible.sh /usr/local/bin/run-ansible.sh
RUN chmod +x /usr/local/bin/run-ansible.sh

ENTRYPOINT [""]
