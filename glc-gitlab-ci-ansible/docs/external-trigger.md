# Запуск Ansible из других GitLab-проектов

Три способа запустить playbooks/roles из `gitlab_ansible` из другого GitLab-проекта.

## Способ 1: Pipeline trigger (рекомендуется)

В `.gitlab-ci.yml` вашего проекта:

```yaml
stages:
  - build
  - deploy

trigger_ansible_web:
  stage: deploy
  trigger:
    project: infrastructure/gitlab_ansible
    branch: main
    strategy: depend
  variables:
    TARGET: "deploy-web"
    EXECUTOR: "shell"
    TAGS: "deploy"
    EXTRA_VARS: "version=${CI_COMMIT_TAG}"
    CHECK_MODE: "false"
  rules:
    - if: $CI_COMMIT_TAG
      when: manual
  needs: []
```

`strategy: depend` — pipeline вызывающего проекта ждёт завершения Ansible pipeline.

### Передаваемые variables

| Variable | Пример | Описание |
|---|---|---|
| `TARGET` | `deploy-web` | Какой job запустить |
| `EXECUTOR` | `shell` | shell или docker |
| `TAGS` | `nginx,deploy` | Ansible tags |
| `EXTRA_VARS` | `version=2.0` | Доп. переменные |
| `CHECK_MODE` | `true` | Dry-run |
| `LIMIT` | `web01` | Ограничение хостов |

## Способ 2: Include-шаблон

Подключите готовый шаблон из `gitlab_ansible`:

```yaml
include:
  - project: infrastructure/gitlab_ansible
    ref: main
    file: ci/templates/trigger-external.yml

stages:
  - deploy

# Используйте готовые jobs:
#   trigger:ansible:deploy-web
#   trigger:ansible:deploy-db
#   trigger:ansible:custom
```

### Запуск custom target

```yaml
# В Run pipeline укажите:
# ANSIBLE_TARGET=deploy-web
# EXECUTOR=shell
# TAGS=deploy
```

Для `trigger:ansible:custom` передайте любые variables:

```yaml
variables:
  ANSIBLE_TARGET: "role-nginx"
  EXECUTOR: "shell"
  INVENTORY: "project-web"
  TAGS: "install"
  EXTRA_VARS: "nginx_port=8080"
```

## Способ 3: Trigger token (API / webhook)

### Создание token

1. Откройте `gitlab_ansible` → **Settings → CI/CD → Pipeline triggers**
2. **Add trigger** → скопируйте token
3. Сохраните token как CI Variable `ANSIBLE_TRIGGER_TOKEN` (masked) в вызывающем проекте

### Вызов через curl

```bash
curl --request POST \
  --form "token=${ANSIBLE_TRIGGER_TOKEN}" \
  --form "ref=main" \
  --form "variables[TARGET]=deploy-web" \
  --form "variables[EXECUTOR]=shell" \
  --form "variables[TAGS]=deploy" \
  --form "variables[EXTRA_VARS]=version=1.0.0" \
  "https://gitlab.company.local/api/v4/projects/<PROJECT_ID>/trigger/pipeline"
```

### Вызов из GitLab CI job

```yaml
trigger_ansible_api:
  stage: deploy
  script:
    - |
      curl --fail --request POST \
        --form "token=${ANSIBLE_TRIGGER_TOKEN}" \
        --form "ref=main" \
        --form "variables[TARGET]=deploy-web" \
        --form "variables[EXECUTOR]=shell" \
        --form "variables[CHECK_MODE]=true" \
        "${CI_API_V4_URL}/projects/${ANSIBLE_PROJECT_ID}/trigger/pipeline"
  rules:
    - when: manual
```

## Пример: деплой приложения + инфраструктура

```yaml
stages:
  - build
  - test
  - deploy_app
  - deploy_infra

build:
  stage: build
  script:
    - echo "Building application..."

deploy_app:
  stage: deploy_app
  script:
    - echo "Deploying application..."
  rules:
    - if: $CI_COMMIT_TAG

deploy_infra:
  stage: deploy_infra
  trigger:
    project: infrastructure/gitlab_ansible
    branch: main
    strategy: depend
  variables:
    TARGET: "deploy-web"
    EXECUTOR: "shell"
    EXTRA_VARS: "app_version=${CI_COMMIT_TAG}"
  rules:
    - if: $CI_COMMIT_TAG
      when: manual
  needs:
    - deploy_app
```

## Мониторинг результата

1. В вызывающем проекте: pipeline показывает downstream pipeline (при `strategy: depend`)
2. В `gitlab_ansible`: Job → Browse artifacts → `logs/` — полный лог выполнения
3. Pipeline status API:

```bash
curl --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${CI_API_V4_URL}/projects/${ANSIBLE_PROJECT_ID}/pipelines/${PIPELINE_ID}"
```

## Безопасность

- Используйте **protected** variables для production targets
- Ограничьте trigger token только protected branches
- Не передавайте `ANSIBLE_VAULT_PASSWORD` из вызывающего проекта — храните его только в `gitlab_ansible`
- Используйте `when: manual` для production deploys

## Связанные документы

- [README](../README.md)
- [Настройка GitLab проекта](gitlab-setup.md)
- [Настройка shell runner](runner-shell-setup.md)
