# gitlab_ansible — Единый GitLab CI для Ansible (IaC)

Централизованный репозиторий для Ansible playbooks, roles и inventory с универсальным GitLab CI/CD pipeline.

## Возможности

- **Monorepo** — все roles, playbooks и inventory в одном проекте
- **Один CI job = один playbook/role** — изолированный запуск через переменную `TARGET`
- **Inventory по проектам** — hosts разделены по каталогам `inventories/project-*`
- **Shell runner (основной)** и **Docker runner (опционально)** — выбор через `EXECUTOR`
- **Централизованные логи** — каждый запуск сохраняется в `logs/` как CI artifact
- **Trigger из других проектов** — pipeline trigger и include-шаблон

## Быстрый старт

### 1. Создайте проект в GitLab

```bash
git remote add origin https://gitlab.company.local/infrastructure/gitlab_ansible.git
git push -u origin main
```

Подробнее: [docs/gitlab-setup.md](docs/gitlab-setup.md)

### 2. Настройте shell runner

Следуйте инструкции: [docs/runner-shell-setup.md](docs/runner-shell-setup.md)

Runner должен иметь tag `ansible-shell`.

### 3. Добавьте CI/CD Variables

| Variable | Type | Protected | Masked |
|---|---|---|---|
| `ANSIBLE_VAULT_PASSWORD` | Variable | Yes | Yes |

### 4. Запустите pipeline

**GitLab UI:** CI/CD → Pipelines → Run pipeline

| Variable | Value | Описание |
|---|---|---|
| `TARGET` | `deploy-web` | Какой job запустить |
| `EXECUTOR` | `shell` | shell или docker |
| `CHECK_MODE` | `true` | Dry-run без изменений |
| `TAGS` | `nginx` | Ansible tags |
| `EXTRA_VARS` | `version=1.0` | Доп. переменные |

## Структура репозитория

```
gitlab_ansible/
├── .gitlab-ci.yml              # Корневой pipeline
├── ansible.cfg
├── ci/
│   ├── templates/              # CI-шаблоны (include)
│   ├── scripts/run-ansible.sh  # Единый скрипт запуска
│   └── docker/Dockerfile
├── inventories/
│   ├── project-web/            # Inventory для web-проекта
│   ├── project-db/
│   └── project-monitoring/
├── playbooks/
│   ├── deploy-web/
│   │   ├── playbook.yml
│   │   └── ci.yml              # Метаданные CI
│   └── deploy-db/
├── roles/
│   ├── nginx/
│   └── postgresql/
├── logs/                       # CI artifacts (логи)
└── docs/
```

## Доступные TARGET values

| TARGET | Тип | Inventory | Описание |
|---|---|---|---|
| `deploy-web` | playbook | project-web | Деплой web-серверов |
| `deploy-db` | playbook | project-db | Деплой БД |
| `role-nginx` | role | project-web | Запуск role nginx |
| `role-postgresql` | role | project-db | Запуск role postgresql |

## Переменные CI/CD

| Variable | Default | Описание |
|---|---|---|
| `TARGET` | — | Имя job/playbook для запуска |
| `EXECUTOR` | `shell` | `shell` или `docker` |
| `PLAYBOOK` | — | Путь к playbook (для manual:run) |
| `ROLE` | — | Имя role (для manual:run) |
| `INVENTORY` | из ci.yml | Каталог inventory |
| `TAGS` | — | Ansible --tags |
| `SKIP_TAGS` | — | Ansible --skip-tags |
| `LIMIT` | — | Ansible --limit |
| `EXTRA_VARS` | — | Доп. переменные |
| `CHECK_MODE` | `false` | Dry-run |
| `DIFF_MODE` | `false` | Показ diff |
| `VERBOSITY` | — | v, vv, vvv |
| `MANUAL_RUN` | — | `true` для generic job |
| `VALIDATE_ONLY` | — | `true` — только validate stage |

## Логи

Каждый запуск создаёт файл:

```
logs/<pipeline_id>_<job_name>_<timestamp>.log
```

Логи доступны 30 дней: Job → Browse artifacts → `logs/`

## Запуск из других проектов

См. [docs/external-trigger.md](docs/external-trigger.md)

## Добавление нового playbook

1. Создайте каталог `playbooks/my-playbook/`
2. Добавьте `playbook.yml` и `ci.yml`
3. Создайте inventory `inventories/my-project/hosts.yml`
4. Добавьте job в `ci/templates/ansible-run.yml`:

```yaml
deploy:my-playbook:
  extends: .ansible_run
  variables:
    TARGET: my-playbook
    PLAYBOOK: playbooks/my-playbook/playbook.yml
    INVENTORY: my-project
  rules:
    - if: $TARGET == "my-playbook"
      when: manual
```

## Локальная проверка

```bash
# Syntax check
ansible-playbook --syntax-check playbooks/deploy-web/playbook.yml

# Inventory
ansible-inventory -i inventories/project-web/hosts.yml --graph

# Dry-run (нужен доступ к хостам)
ansible-playbook -i inventories/project-web/hosts.yml \
  playbooks/deploy-web/playbook.yml --check
```

## Документация

- [Настройка shell runner](docs/runner-shell-setup.md)
- [Запуск из других проектов](docs/external-trigger.md)
- [Настройка GitLab проекта](docs/gitlab-setup.md)
