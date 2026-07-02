Режим **Ask** — я не могу создать репозиторий и файлы за вас, но ниже готовая архитектура проекта, которую можно сразу реализовать. Она опирается на ваши шаблоны из `gitlab_ansible_role_playbook_docker.md` и `gitlab_ansible_playbooks.md`.

---

## Цель проекта

GitLab CI/CD + Ansible для безопасного обновления **Ubuntu** и **Oracle Linux 9** с:
- предварительными проверками,
- поэтапным логированием,
- отчётом после обновления,
- настройкой параметров через **Run pipeline** в GitLab.

---

## Структура репозитория

```
linux-os-update/
├── .gitlab-ci.yml
├── ansible.cfg
├── requirements.yml
├── site.yml                          # главный плейбук (все этапы)
├── inventory/
│   ├── production/
│   │   ├── hosts.yml
│   │   └── group_vars/
│   │       ├── all.yml
│   │       ├── ubuntu.yml
│   │       └── ol9.yml
│   └── staging/
│       └── ...
├── playbooks/
│   ├── pre_check.yml
│   ├── update.yml
│   └── report.yml
├── roles/
│   ├── common_logging/               # единый логгер этапов
│   ├── pre_check_repos/              # проверка репозиториев
│   ├── pre_check_connectivity/       # доступность mirror/repo
│   ├── pre_check_locks/              # apt/dnf/yum locks
│   ├── os_update_ubuntu/
│   ├── os_update_ol9/
│   └── post_update_report/
├── templates/
│   └── report.html.j2
├── logs/                             # артефакты CI (создаётся в runtime)
└── reports/
```

---

## Этапы выполнения (Ansible tags)

| Этап | Tag | Что делает |
|------|-----|------------|
| 1. Pre-check repos | `precheck_repos` | Проверка `/etc/apt/sources.list*`, `/etc/yum.repos.d/`, `dnf repolist`, `apt-cache policy` |
| 2. Pre-check connectivity | `precheck_connectivity` | `uri`/`get_url`/`ping` к URL репозиториев, DNS, proxy |
| 3. Pre-check locks | `precheck_locks` | `/var/lib/dpkg/lock*`, `/var/run/yum.pid`, `dnf history`, `needs-restarting` |
| 4. Update | `update` | `apt upgrade` / `dnf update --security` |
| 5. Report | `report` | Сбор фактов, diff версий, reboot required, HTML/JSON отчёт |

Главный плейбук `site.yml`:

```yaml
---
- name: Linux OS Update Pipeline
  hosts: all
  gather_facts: true
  serial: "{{ update_serial | default(1) }}"
  vars:
    log_dir: "/var/log/ansible-os-update/{{ ansible_date_time.date }}"
    report_dir: "{{ playbook_dir }}/reports"

  pre_tasks:
    - name: Init stage logging
      ansible.builtin.include_role:
        name: common_logging
        tasks_from: init.yml

  roles:
    - role: pre_check_repos
      tags: [precheck, precheck_repos]
      when: run_precheck | default(true) | bool

    - role: pre_check_connectivity
      tags: [precheck, precheck_connectivity]
      when: run_precheck | default(true) | bool

    - role: pre_check_locks
      tags: [precheck, precheck_locks]
      when: run_precheck | default(true) | bool

    - role: os_update_ubuntu
      tags: [update]
      when:
        - run_update | default(true) | bool
        - ansible_os_family == "Debian"

    - role: os_update_ol9
      tags: [update]
      when:
        - run_update | default(true) | bool
        - ansible_distribution == "OracleLinux"
        - ansible_distribution_major_version == "9"

    - role: post_update_report
      tags: [report]
      when: run_report | default(true) | bool

  post_tasks:
    - name: Finalize logging
      ansible.builtin.include_role:
        name: common_logging
        tasks_from: finalize.yml
```

---

## Предварительные проверки (детали)

### 1. Настройки репозиториев

**Ubuntu:**
- наличие `sources.list` и `sources.list.d/*.list`
- отсутствие `deb cdrom:` в prod
- `apt-cache policy` — есть ли release/candidate
- при `use_internal_mirror=true` — только разрешённые mirror URL

**Oracle Linux 9:**
- файлы в `/etc/yum.repos.d/`
- `dnf repolist enabled`
- включён ли `ol9_*` / `UEKR` / ваш internal mirror
- `subscription-manager status` (если используется)

### 2. Доступность серверов репозиториев

```yaml
# Пример задачи в pre_check_connectivity
- name: Check repo URL availability
  ansible.builtin.uri:
    url: "{{ item }}"
    method: GET
    status_code: [200, 301, 302, 404]
    timeout: 10
  loop: "{{ repo_urls }}"
  register: repo_check
  failed_when: repo_check.status is not defined or repo_check.status >= 500
```

Дополнительно: `wait_for` на 443/80, проверка DNS (`dig`), proxy (`http_proxy`).

### 3. Блокировки (locks)

**Ubuntu:**
```bash
fuser /var/lib/dpkg/lock-frontend
fuser /var/lib/apt/lists/lock
pgrep -a apt | pgrep -a dpkg
```

**OL9:**
```bash
test -f /var/run/yum.pid && cat /var/run/yum.pid
test -f /var/run/dnf.pid
dnf history list last
```

При обнаружении lock — **fail** с понятным сообщением в лог (не продолжать update).

---

## Логирование каждого этапа

Роль `common_logging`:

```yaml
# roles/common_logging/tasks/log_stage.yml
- name: "LOG | {{ stage_name }} | START"
  ansible.builtin.lineinfile:
    path: "{{ log_dir }}/pipeline.log"
    line: "[{{ ansible_date_time.iso8601 }}] [{{ inventory_hostname }}] [{{ stage_name }}] START"
    create: true
  delegate_to: localhost
  run_once: false

- name: "LOG | {{ stage_name }} | END"
  ansible.builtin.lineinfile:
    path: "{{ log_dir }}/pipeline.log"
    line: "[{{ ansible_date_time.iso8601 }}] [{{ inventory_hostname }}] [{{ stage_name }}] END status={{ stage_status }}"
    create: true
  delegate_to: localhost
```

В `ansible.cfg`:

```ini
[defaults]
log_path = ./logs/ansible.log
callback_whitelist = profile_tasks, timer, json
stdout_callback = yaml

[callback_json]
log_file = ./logs/ansible-json.log
```

В GitLab CI — сохранять `logs/` и `reports/` как artifacts.

---

## Отчёт после обновления

Роль `post_update_report` собирает:

- hostname, OS, kernel до/после
- список обновлённых пакетов (`apt list --upgradable` / `dnf history info`)
- требуется ли reboot (`/var/run/reboot-required`, `needs-restarting -r`)
- результат pre-check
- ошибки/предупреждения

**Форматы:**
- `reports/update-report-{{ inventory_hostname }}.json`
- `reports/update-report-{{ inventory_hostname }}.html` (шаблон Jinja2)
- сводный `reports/summary.json` (через `run_once` + `set_fact`)

Пример JSON:

```json
{
  "hostname": "web-01",
  "os": "Ubuntu 22.04",
  "started_at": "2026-07-02T10:00:00",
  "finished_at": "2026-07-02T10:25:00",
  "precheck": {"repos": "ok", "connectivity": "ok", "locks": "ok"},
  "packages_updated": 42,
  "reboot_required": true,
  "status": "success"
}
```

---

## GitLab CI — параметры перед запуском

Рекомендуется **GitLab 15.7+** с `spec.inputs` (удобнее, чем только CI Variables):

```yaml
spec:
  inputs:
    inventory:
      description: "Inventory (production/staging)"
      default: production
      options: [production, staging]
    target_hosts:
      description: "Ansible --limit (например web:&ubuntu)"
      default: "all"
    os_family:
      description: "Фильтр ОС"
      default: "all"
      options: [all, ubuntu, ol9]
    run_precheck:
      type: boolean
      default: true
    run_update:
      type: boolean
      default: true
    run_report:
      type: boolean
      default: true
    update_type:
      description: "Тип обновления"
      default: security
      options: [security, all]
    reboot_if_required:
      type: boolean
      default: false
    check_mode:
      type: boolean
      default: false
    update_serial:
      description: "Кол-во хостов одновременно"
      default: "1"

---

stages:
  - validate
  - precheck
  - update
  - report

variables:
  ANSIBLE_FORCE_COLOR: "1"
  ANSIBLE_ROLES_PATH: "${CI_PROJECT_DIR}/roles"
  DOCKER_IMAGE: "quay.io/ansible/ansible-runner:latest"

.ansible_base:
  image: $DOCKER_IMAGE
  tags: [ansible]
  before_script:
    - mkdir -p logs reports
    - ansible-galaxy install -r requirements.yml -p roles || true
    - echo "$SSH_PRIVATE_KEY" | tr -d '\r' > id_rsa && chmod 600 id_rsa
    - export ANSIBLE_PRIVATE_KEY_FILE=$CI_PROJECT_DIR/id_rsa

validate:
  stage: validate
  extends: .ansible_base
  script:
    - ansible-playbook site.yml --syntax-check
    - ansible-lint site.yml || true
  rules:
    - when: always

precheck:
  stage: precheck
  extends: .ansible_base
  script:
    - |
      ansible-playbook site.yml \
        -i inventory/$[[ inputs.inventory ]]/hosts.yml \
        --limit "$[[ inputs.target_hosts ]]" \
        --tags precheck \
        --extra-vars '{
          "run_precheck": $[[ inputs.run_precheck ]],
          "run_update": false,
          "run_report": false,
          "update_type": "$[[ inputs.update_type ]]"
        }' \
        ${CHECK_MODE:+--check}
  artifacts:
    paths: [logs/, reports/]
    expire_in: 30 days
  rules:
    - when: manual

update:
  stage: update
  extends: .ansible_base
  needs: [precheck]
  script:
    - |
      EXTRA="run_update=$[[ inputs.run_update ]] reboot_if_required=$[[ inputs.reboot_if_required ]]"
      ansible-playbook site.yml \
        -i inventory/$[[ inputs.inventory ]]/hosts.yml \
        --limit "$[[ inputs.target_hosts ]]" \
        --tags update \
        --extra-vars "$EXTRA update_type=$[[ inputs.update_type ]] update_serial=$[[ inputs.update_serial ]]" \
        $([[ "$[[ inputs.check_mode ]]" == "true" ]] && echo "--check")
  artifacts:
    paths: [logs/, reports/]
  rules:
    - when: manual

report:
  stage: report
  extends: .ansible_base
  needs: [update]
  script:
    - |
      ansible-playbook site.yml \
        -i inventory/$[[ inputs.inventory ]]/hosts.yml \
        --limit "$[[ inputs.target_hosts ]]" \
        --tags report \
        --extra-vars "run_report=$[[ inputs.run_report ]]"
  artifacts:
    name: "os-update-report-$CI_PIPELINE_ID"
    paths: [reports/, logs/]
    expire_in: 90 days
  rules:
    - when: on_success
```

**Запуск:** CI/CD → Pipelines → **Run pipeline** → выбрать branch → задать параметры (inventory, limit, тип обновления и т.д.).

---

## Переменные плейбука (group_vars)

`inventory/production/group_vars/all.yml`:

```yaml
repo_urls:
  - "https://archive.ubuntu.com/ubuntu/"
  - "https://yum.oracle.com/"

allowed_ubuntu_mirrors:
  - "https://mirror.internal.corp/ubuntu/"

update_serial: 1
update_type: security          # security | all
reboot_if_required: false
fail_on_lock: true
log_to_gitlab_artifact: true
```

`inventory/production/group_vars/ubuntu.yml`:

```yaml
apt_update_options:
  - "-y"
  - "--no-install-recommends"
```

`inventory/production/group_vars/ol9.yml`:

```yaml
dnf_update_options:
  - "--security"   # при update_type=security
  - "-y"
```

---

## Inventory (пример)

```yaml
# inventory/production/hosts.yml
all:
  children:
    ubuntu:
      hosts:
        web-01.example.com:
        db-01.example.com:
    ol9:
      hosts:
        app-01.example.com:
        app-02.example.com:
```

---

## Роли обновления (кратко)

**Ubuntu (`os_update_ubuntu`):**
1. `apt-get update`
2. snapshot пакетов до обновления
3. `apt upgrade` или `unattended-upgrade` (по `update_type`)
4. проверка `/var/run/reboot-required`
5. опционально reboot

**Oracle Linux 9 (`os_update_ol9`):**
1. `dnf clean all && dnf makecache`
2. `dnf update --security` или `dnf update`
3. `needs-restarting -r`
4. опционально reboot

---

## Безопасность (по вашему регламенту)

- SSH-ключ в GitLab CI Variable `SSH_PRIVATE_KEY` (masked, protected)
- Vault для паролей: `ansible-vault` + `ANSIBLE_VAULT_PASSWORD`
- Production — только **manual** jobs
- `serial: 1` по умолчанию для rolling update
- `--check` через параметр `check_mode` перед боевым запуском

---

## Рекомендуемый workflow оператора

1. **Run pipeline** с `check_mode=true`, `run_update=false` — dry-run precheck  
2. **Run pipeline** precheck → update (security) → report  
3. Скачать artifact `reports/` из GitLab  
4. При `reboot_required=true` — отдельный pipeline с `reboot_if_required=true`

---

## Что можно добавить позже

- Molecule-тесты для ролей (Ubuntu + OL9 контейнеры)
- интеграция с AWX/Tower
- отправка отчёта в email/Slack/Telegram
- compliance-check (CIS, OpenSCAP)

---

Если нужно, чтобы я **создал репозиторий с этими файлами**, переключитесь в **Agent mode** — тогда смогу сгенерировать полный проект (roles, playbooks, `.gitlab-ci.yml`, README) в `~/Projects/linux-os-update` или в указанную вами директорию.

Уточните также:
- используете **GitLab Runner** с тегом `ansible` или Docker executor?
- обновление через **internal mirror** или публичные репозитории?
- нужен ли **автоматический reboot** после обновления?
