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



   Я доработал исходный `.gitlab-ci.yml`, интегрировав в него:

- автоматическую загрузку Ansible-ролей из отдельного GitLab-репозитория (стадия `prepare`),
- передачу ролей через артефакты во все джобы деплоя и линтера,
- сохранение механики ручного выбора типа (stage `type`) и зависимостей `needs`,
- использование единого образа `devupsen/ansible:6.5.0`,
- корректную работу SSH-агента с ключом из переменной `SSH_KEY`.

```yaml
stages:
  - type
  - prepare
  - lint
  - infra
  - bootstrap
  - gitlab
  - balancers

variables:
  ANSIBLE_CONFIG: "./ansible.cfg"
  PLAYBOOK: "playbooks/test.yml"
  LIMIT: "all"
  EXTRAVARS: "empty=true"
  TAGS: "all"

# ------------------------------------------------------------
# Шаблоны
# ------------------------------------------------------------

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
    - echo "Запуск плейбука: $PLAYBOOK"
    - ansible-playbook playbooks/$PLAYBOOK -l $LIMIT -e "$EXTRAVARS" -t $TAGS
  rules:
    - if: '$CI_PIPELINE_SOURCE == "web"'
      when: manual

# Заглушка для выбора типа деплоя
.register-type:
  stage: type
  script: echo "CHOOSE TYPE: $CI_JOB_NAME"
  rules:
    - if: '$CI_PIPELINE_SOURCE == "web"'
      when: manual

# ------------------------------------------------------------
# Стадия подготовки: загрузка Ansible-ролей из внешнего репо
# ------------------------------------------------------------
prepare_roles:
  stage: prepare
  image:
    name: devupsen/ansible:6.5.0
  script:
    # Подстановка CI_JOB_TOKEN в requirements.yml
    - sed "s|\${CI_JOB_TOKEN}|${CI_JOB_TOKEN}|g" requirements.yml > requirements_resolved.yml
    - ansible-galaxy install -r requirements_resolved.yml -p roles/ --force
  artifacts:
    paths:
      - roles/
    expire_in: 1 hour

# ------------------------------------------------------------
# Линтер Ansible (только на merge requests)
# ------------------------------------------------------------
ansible-linter:
  stage: lint
  image:
    name: devupsen/ansible:6.5.0
  script:
    - ansible-lint
  needs:
    - prepare_roles          # роли должны быть доступны для проверки
  only:
    - merge_requests

# ------------------------------------------------------------
# Ручные джобы-селекторы (stage: type)
# ------------------------------------------------------------
infra:
  extends: .register-type

bootstrap:
  extends: .register-type

gitlab:
  extends: .register-type

balancers:
  extends: .register-type

# ------------------------------------------------------------
# Задачи деплоя (зависят от выбранного типа + ролей)
# ------------------------------------------------------------

# Установка Docker
docker:
  stage: bootstrap
  extends: .run-playbook
  needs:
    - job: bootstrap
      artifacts: false
    - job: prepare_roles
      artifacts: true
  variables:
    PLAYBOOK: "docker.yaml"
    LIMIT: "devupsen"

# Установка GitLab Runner
runner:
  stage: gitlab
  extends: .run-playbook
  needs:
    - job: gitlab
      artifacts: false
    - job: prepare_roles
      artifacts: true
  variables:
    PLAYBOOK: "gitlab-runner.yaml"

# Настройка Vault и Postgres
vault:
  stage: infra
  extends: .run-playbook
  needs:
    - job: infra
      artifacts: false
    - job: prepare_roles
      artifacts: true
  variables:
    PLAYBOOK: "vault.yaml"
    EXTRAVARS: 'postgres_vault.password="$VAULT_POSTGRES_PASSWORD"'

# Основной балансировщик (Зеленый/Желтый)
main:
  stage: balancers
  extends: .run-playbook
  needs:
    - job: balancers
      artifacts: false
    - job: prepare_roles
      artifacts: true
  variables:
    PLAYBOOK: "nginx.yaml"
    LIMIT: "balancer-green.devupsen.ru,balancer-yellow.devupsen.ru"
    TAGS: "main"

# Резервный балансировщик (Красный)
second:
  stage: balancers
  extends: .run-playbook
  needs:
    - job: balancers
      artifacts: false
    - job: prepare_roles
      artifacts: true
  variables:
    PLAYBOOK: "nginx.yaml"
    LIMIT: "balancer-red.devupsen.ru"
    TAGS: "backup-node,main"
```

**Основные изменения и почему так:**

1. **Добавлена стадия `prepare`** – она идёт сразу после ручного выбора типа и загружает роли через `ansible-galaxy`.  
   - Используется `sed` для подстановки `CI_JOB_TOKEN` (образы на базе Alpine могут не иметь `envsubst`).  
   - Артефакт `roles/` живёт 1 час и передаётся всем нуждающимся джобам.

2. **Все деплой-джобы явно указывают `needs: [job: <type-selector>, job: prepare_roles]`.**  
   - Без этого при использовании `needs` артефакты из предыдущих стадий не подхватываются, и роли не были бы доступны.  
   - Для селекторов (`bootstrap`, `infra` и т.д.) установлено `artifacts: false`, так как они не производят артефактов.

3. **Линтер (ansible-linter) теперь также зависит от `prepare_roles`**, чтобы иметь доступ к загруженным ролям и корректно проверять плейбуки.

4. **Оставлен оригинальный образ `devupsen/ansible:6.5.0`** – он используется во всех задачах, включая подготовку и линтер. Это гарантирует единообразие окружения.

5. **Механика выбора типа осталась неизменной** – джобы `infra`, `bootstrap`, `gitlab`, `balancers` появляются только при запуске пайплайна через веб-интерфейс и ожидают ручного нажатия. После их запуска стартует соответствующая джоба деплоя.

6. **Переменные CI/CD** (`SSH_KEY`, `VAULT_POSTGRES_PASSWORD`, `CI_JOB_TOKEN`) должны быть заранее добавлены в настройках проекта (Settings → CI/CD → Variables). `CI_JOB_TOKEN` доступен автоматически.

7. **Файл `requirements.yml`** должен присутствовать в корне проекта и выглядеть, например, так:

```yaml
- src: https://gitlab-ci-token:${CI_JOB_TOKEN}@gitlab.example.com/group/ansible-roles.git
  scm: git
  version: main
  name: my_role
```

Теперь вы имеете полный пайплайн, который:
- автоматически проверяет стиль при создании merge request,
- при ручном запуске позволяет выбрать тип инфраструктурной задачи,
- подгружает роли из отдельного GitLab-репозитория и выполняет соответствующий плейбук.

**Важное замечание из кода:**
В строках 64-65 есть жесткая привязка `LIMIT: "devupsen"`. Убедитесь, что в вашем инвентарном файле Ansible есть группа или хост с именем `devupsen`. Иначе первый же плейбук (`docker`) не найдет, на что ему устанавливаться.
----------------------------------------------
----------------------------------------------


Мы переработали проект под **shell runner** с тегом `ansible-server`, полностью исключив Docker.  
Все задачи выполняются напрямую на сервере, где уже установлены Ansible, `ansible-lint`, `git`, `ssh-agent` и необходимые зависимости.

### Основные изменения
- Убран параметр `image` во всех job’ах.
- Добавлен тег `tags: [ansible-server]` для каждой job’ы, чтобы она назначалась на нужный раннер.
- Логика работы с SSH-ключом и артефактами остаётся прежней, но выполняется локально.
- Стадии и ручной выбор типа сохранены полностью.

## 1. `.gitlab-ci.yml`

```yaml
stages:
  - type
  - prepare
  - lint
  - infra
  - bootstrap
  - gitlab
  - balancers

variables:
  ANSIBLE_CONFIG: "./ansible.cfg"
  PLAYBOOK: "playbooks/test.yml"
  LIMIT: "all"
  EXTRAVARS: "empty=true"
  TAGS: "all"

# ------------------------------------------------------------
# Шаблоны
# ------------------------------------------------------------

# Шаблон запуска Ansible-плейбуков (shell runner)
.run-playbook:
  tags:
    - ansible-server
  before_script:
    - export ANSIBLE_CONFIG=./ansible.cfg
    - eval $(ssh-agent -s)
    - echo "$SSH_KEY" | tr -d '\r' | ssh-add -
    - mkdir -p ~/.ssh
    - chmod 700 ~/.ssh
  script:
    - echo "Запуск плейбука: $PLAYBOOK"
    - ansible-playbook playbooks/$PLAYBOOK -l $LIMIT -e "$EXTRAVARS" -t $TAGS
  rules:
    - if: '$CI_PIPELINE_SOURCE == "web"'
      when: manual

# Заглушка для выбора типа деплоя
.register-type:
  stage: type
  tags:
    - ansible-server
  script: echo "CHOOSE TYPE: $CI_JOB_NAME"
  rules:
    - if: '$CI_PIPELINE_SOURCE == "web"'
      when: manual

# ------------------------------------------------------------
# Стадия подготовки: загрузка Ansible-ролей из отдельного репо
# ------------------------------------------------------------
prepare_roles:
  stage: prepare
  tags:
    - ansible-server
  script:
    # Подстановка CI_JOB_TOKEN (shell runner, используем sed)
    - sed "s|\${CI_JOB_TOKEN}|${CI_JOB_TOKEN}|g" requirements.yml > requirements_resolved.yml
    - ansible-galaxy install -r requirements_resolved.yml -p roles/ --force
  artifacts:
    paths:
      - roles/
    expire_in: 1 hour

# ------------------------------------------------------------
# Линтер Ansible (только на merge requests)
# ------------------------------------------------------------
ansible-linter:
  stage: lint
  tags:
    - ansible-server
  script:
    - ansible-lint
  needs:
    - prepare_roles
  only:
    - merge_requests

# ------------------------------------------------------------
# Ручные джобы-селекторы (stage: type)
# ------------------------------------------------------------
infra:
  extends: .register-type

bootstrap:
  extends: .register-type

gitlab:
  extends: .register-type

balancers:
  extends: .register-type

# ------------------------------------------------------------
# Задачи деплоя (зависят от выбранного типа и ролей)
# ------------------------------------------------------------

# Установка Docker (хотя Docker не используется, оставим как пример)
docker:
  stage: bootstrap
  extends: .run-playbook
  needs:
    - job: bootstrap
      artifacts: false
    - job: prepare_roles
      artifacts: true
  variables:
    PLAYBOOK: "docker.yaml"
    LIMIT: "devupsen"

# Установка GitLab Runner
runner:
  stage: gitlab
  extends: .run-playbook
  needs:
    - job: gitlab
      artifacts: false
    - job: prepare_roles
      artifacts: true
  variables:
    PLAYBOOK: "gitlab-runner.yaml"

# Настройка Vault и Postgres
vault:
  stage: infra
  extends: .run-playbook
  needs:
    - job: infra
      artifacts: false
    - job: prepare_roles
      artifacts: true
  variables:
    PLAYBOOK: "vault.yaml"
    EXTRAVARS: 'postgres_vault.password="$VAULT_POSTGRES_PASSWORD"'

# Основной балансировщик (Зелёный/Жёлтый)
main:
  stage: balancers
  extends: .run-playbook
  needs:
    - job: balancers
      artifacts: false
    - job: prepare_roles
      artifacts: true
  variables:
    PLAYBOOK: "nginx.yaml"
    LIMIT: "balancer-green.devupsen.ru,balancer-yellow.devupsen.ru"
    TAGS: "main"

# Резервный балансировщик (Красный)
second:
  stage: balancers
  extends: .run-playbook
  needs:
    - job: balancers
      artifacts: false
    - job: prepare_roles
      artifacts: true
  variables:
    PLAYBOOK: "nginx.yaml"
    LIMIT: "balancer-red.devupsen.ru"
    TAGS: "backup-node,main"
```

## 2. Требования к серверу-раннеру (ansible-server)

На сервере, где запущен GitLab Runner с executor **shell** и тегом `ansible-server`, должны быть установлены:

- **Ansible** (рекомендуется версия, совместимая с вашими плейбуками, например, `ansible >= 2.9`)
- **ansible-lint** (для стадии lint)
- **git**
- **openssh-client** и **ssh-agent**
- **Python** (обычно уже есть)

Дополнительно:
- В переменных GitLab CI/CD должны быть заданы `SSH_KEY` (приватный ключ для доступа к целевым хостам) и, при необходимости, другие секреты (`VAULT_POSTGRES_PASSWORD` и т.п.).
- `CI_JOB_TOKEN` доступен автоматически.

## 3. Структура проекта (без Docker)

Проект сохраняет ту же файловую структуру, что и раньше, за исключением отсутствия Dockerfile и упоминаний Docker:

```
ansible-playbooks/
├── .gitlab-ci.yml
├── requirements.yml
├── ansible.cfg
├── .ansible-lint
├── playbooks/
│   └── ... (ваши плейбуки docker.yaml, gitlab-runner.yaml и т.д.)
├── inventory/
│   ├── staging.yml
│   ├── production.yml
│   └── ...
├── roles/          # будет заполнена через ansible-galaxy
└── README.md
```

## 4. Пример `requirements.yml`

```yaml
- src: https://gitlab-ci-token:${CI_JOB_TOKEN}@gitlab.example.com/group/ansible-roles.git
  scm: git
  version: main
  name: my_role
```

Теперь пайплайн полностью выполняется на выделенном сервере без Docker, роли подтягиваются из отдельного репозитория, а ручной выбор типа деплоя сохранён.
