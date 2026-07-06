# Настройка GitLab Runner (shell executor)

Инструкция по установке и настройке shell runner для запуска Ansible playbooks.

## Требования к серверу-раннеру

- Linux (Ubuntu 22.04+ / RHEL 8+)
- Доступ к GitLab (`https://gitlab.company.local`)
- Сетевой доступ к target hosts (SSH)
- Ansible 2.14+ установлен
- Пользователь `gitlab-runner` с SSH-ключом на target hosts

## 1. Установка GitLab Runner

### Ubuntu/Debian

```bash
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | sudo bash
sudo apt-get install gitlab-runner
```

### RHEL/CentOS

```bash
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh" | sudo bash
sudo yum install gitlab-runner
```

## 2. Регистрация runner

Получите registration token:
**GitLab → Settings → CI/CD → Runners → New project runner** (или group/instance runner token).

```bash
sudo gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.company.local" \
  --token "<RUNNER_AUTH_TOKEN>" \
  --executor "shell" \
  --description "ansible-shell-runner" \
  --tag-list "ansible-shell" \
  --run-untagged="false" \
  --locked="false"
```

## 3. Конфигурация `/etc/gitlab-runner/config.toml`

```toml
concurrent = 4
check_interval = 0
shutdown_timeout = 0

[session_server]
  session_timeout = 1800

[[runners]]
  name = "ansible-shell-runner"
  url = "https://gitlab.company.local"
  id = 1
  token = "<RUNNER_TOKEN>"
  token_obtained_at = 2026-01-01T00:00:00Z
  token_expires_at = 0001-01-01T00:00:00Z
  executor = "shell"
  shell = "bash"
  tag_list = ["ansible-shell"]
  run_untagged = false
  locked = false

  environment = [
    "ANSIBLE_FORCE_COLOR=1",
    "ANSIBLE_HOST_KEY_CHECKING=True"
  ]

  [runners.cache]
    MaxUploadedArchiveSize = 0
```

После изменений:

```bash
sudo gitlab-runner restart
sudo gitlab-runner verify
```

## 4. Установка Ansible на runner

### Через pip (рекомендуется)

```bash
sudo apt-get install -y python3-pip python3-venv
sudo pip3 install ansible ansible-lint yamllint
ansible --version
```

### Через PPA (Ubuntu)

```bash
sudo apt-add-repository --yes --update ppa:ansible/ansible
sudo apt-get install -y ansible ansible-lint
```

## 5. Настройка SSH-доступа

Runner выполняет jobs от пользователя `gitlab-runner`. Ему нужен SSH-доступ к target hosts.

```bash
# Создать SSH-ключ (если нет)
sudo -u gitlab-runner ssh-keygen -t ed25519 -C "gitlab-runner@ansible" -f /home/gitlab-runner/.ssh/id_ed25519 -N ""

# Показать публичный ключ
sudo cat /home/gitlab-runner/.ssh/id_ed25519.pub
```

Добавьте публичный ключ в `authorized_keys` на target hosts (или через Ansible role `add_ansible_user`).

### SSH config для gitlab-runner

```bash
sudo -u gitlab-runner tee /home/gitlab-runner/.ssh/config << 'EOF'
Host *
  StrictHostKeyChecking accept-new
  ControlMaster auto
  ControlPersist 60s
  IdentityFile ~/.ssh/id_ed25519
EOF
sudo chmod 600 /home/gitlab-runner/.ssh/config
sudo chown gitlab-runner:gitlab-runner /home/gitlab-runner/.ssh/config
```

## 6. Права sudo (если playbook использует become)

```bash
echo "gitlab-runner ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/gitlab-runner
sudo chmod 440 /etc/sudoers.d/gitlab-runner
```

> Используйте минимально необходимые права в production.

## 7. Проверка runner

```bash
# Статус runner
sudo gitlab-runner status

# Список runners
sudo gitlab-runner list

# Тест SSH до target host
sudo -u gitlab-runner ssh ansible@192.168.1.10 "hostname"
```

В GitLab: **Settings → CI/CD → Runners** — runner должен быть зелёным (online) с tag `ansible-shell`.

## 8. Docker runner (опционально)

Для изолированного запуска через Docker:

```bash
sudo gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.company.local" \
  --token "<RUNNER_AUTH_TOKEN>" \
  --executor "docker" \
  --description "ansible-docker-runner" \
  --docker-image "willhallonline/ansible:2.16-alpine" \
  --tag-list "ansible-docker" \
  --run-untagged="false"
```

> Docker runner не имеет прямого SSH-доступа к target hosts без дополнительной настройки (SSH keys mount, network mode). Для production рекомендуется **shell runner**.

## Troubleshooting

| Проблема | Решение |
|---|---|
| Job stuck (no runner) | Проверьте tag `ansible-shell` на runner и в job |
| Permission denied (SSH) | Проверьте SSH-ключ gitlab-runner на target hosts |
| ansible: command not found | Установите Ansible для пользователя gitlab-runner |
| Host key verification failed | Добавьте host keys или `StrictHostKeyChecking accept-new` |
| Vault decrypt failed | Проверьте CI Variable `ANSIBLE_VAULT_PASSWORD` |

## Связанные документы

- [README](../README.md)
- [Настройка GitLab проекта](gitlab-setup.md)
- [Запуск из других проектов](external-trigger.md)
