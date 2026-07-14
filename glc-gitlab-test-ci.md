Я распознал текст с ваших скриншотов и восстановил полный файл `.gitlab-ci.yml`. 

Вот готовый код для вашего проекта. Обратите внимание на **несколько важных моментов**, которые я выделил после кода — без них pipeline не запустится корректно (в частности, нужны секретные переменные `SSH_KEY` и `VAULT_POSTGRES_PASSWORD`).

### Восстановленный `.gitlab-ci.yml`

```yaml
stages:
  - type
  - lint
  - infra
  - bootstrap
  - gitlab
  - balancers

variables:
  PLAYBOOK: "playbooks/test.yml"
  LIMIT: "all"
  EXTRAVARS: "empty=true"
  TAGS: "all"

# Шаблон для запуска Ansible плейбуков
.run-playbook:
  image:
    name: devupsen/ansible:6.5.0
  before_script:
    - export ANSIBLE_CONFIG=./ansible.cfg
    - eval $(ssh-agent -s)
    - echo "$SSH_KEY" | tr -d '\r' | ssh-add -
    - mkdir -p ~/.ssh
    - chmod 700 ~/.ssh
  script:
    - echo $PLAYBOOK
    - ansible-playbook playbooks/$PLAYBOOK -l $LIMIT -e $EXTRAVARS -t $TAGS
  rules:
    - if: '$CI_PIPELINE_SOURCE == "web"'
      when: manual

# Шаблон для выбора типа деплоя (заглушка)
.register-type:
  stage: type
  script: echo "CHOOSE TYPE"
  rules:
    - if: '$CI_PIPELINE_SOURCE == "web"'
      when: manual

# Линтер для Ansible
ansible-linter:
  stage: lint
  image:
    name: devupsen/ansible:6.5.0
  script:
    - ansible-lint
  only:
    - merge_requests

# Этапы регистрации типа (служат для ручного запуска)
infra:
  extends: .register-type

bootstrap:
  extends: .register-type

gitlab:
  extends: .register-type

balancers:
  extends: .register-type

# --- Основные задачи деплоя ---

# Установка Docker
docker:
  stage: bootstrap
  extends: .run-playbook
  needs:
    - bootstrap
  variables:
    PLAYBOOK: "docker.yaml"
    LIMIT: "devupsen"

# Установка GitLab Runner
runner:
  stage: gitlab
  extends: .run-playbook
  needs:
    - gitlab
  variables:
    PLAYBOOK: "gitlab-runner.yaml"

# Настройка Vault и Postgres
vault:
  stage: infra
  extends: .run-playbook
  needs:
    - infra
  variables:
    PLAYBOOK: "vault.yaml"
    EXTRAVARS: 'postgres_vault.password="$VAULT_POSTGRES_PASSWORD"'

# Основной балансировщик (Зеленый/Желтый)
main:
  stage: balancers
  extends: .run-playbook
  needs:
    - balancers
  variables:
    PLAYBOOK: "nginx.yaml"
    LIMIT: "balancer-green.devupsen.ru,balancer-yellow.devupsen.ru"
    TAGS: "main"

# Резервный балансировщик (Красный)
second:
  stage: balancers
  extends: .run-playbook
  needs:
    - balancers
  variables:
    PLAYBOOK: "nginx.yaml"
    LIMIT: "balancer-red.devupsen.ru"
    TAGS: "backup-node,main"
```

---

### Как создать GitLab проект и запустить это:

1. **Создайте репозиторий:**
   * Зайдите в GitLab, нажмите **"New project"** -> **"Create blank project"**.
   * Дайте имя (например, `ansible-deployment`), выберите видимость (Private/Internal) и создайте.

2. **Добавьте файлы:**
   * В корне репозитория создайте файл `.gitlab-ci.yml` и вставьте приведенный выше код.
   * Вам **обязательно** понадобятся файлы Ansible в папке `playbooks/`:
     * `playbooks/test.yml` (стандартный, указан в переменных)
     * `playbooks/docker.yaml`
     * `playbooks/gitlab-runner.yaml`
     * `playbooks/vault.yaml`
     * `playbooks/nginx.yaml`
   * Также нужен файл `ansible.cfg` в корне (для настройки Ansible) и файл `inventory` (или `hosts`), чтобы Ansible знал, какие серверы атаковать, соответствующие доменам (`devupsen`, `balancer-green.devupsen.ru` и т.д.).

3. **Обязательно настройте CI/CD переменные (Settings -> CI/CD -> Variables):**
   * **`SSH_KEY`** (Type: File или Variable) — Приватный SSH ключ, который позволит GitLab Runner подключаться к вашим серверам по SSH.
   * **`VAULT_POSTGRES_PASSWORD`** (Type: Variable) — Пароль от базы данных, который будет подставлен в плейбук `vault.yaml`.

4. **Запуск:**
   * Когда вы закоммитите файл, появится конвейер (pipeline).
   * На этапе `type` (первые джобы `infra`, `bootstrap`, `gitlab`, `balancers`) вам нужно будет **зайти в UI GitLab и нажать кнопку "Play"** вручную, так как в коде прописано `when: manual`.
   * Если вы сделаете Merge Request, сработает `ansible-linter` и проверит код Ansible на ошибки.

**Важное замечание из кода:**
В строках 64-65 есть жесткая привязка `LIMIT: "devupsen"`. Убедитесь, что в вашем инвентарном файле Ansible есть группа или хост с именем `devupsen`. Иначе первый же плейбук (`docker`) не найдет, на что ему устанавливаться.
