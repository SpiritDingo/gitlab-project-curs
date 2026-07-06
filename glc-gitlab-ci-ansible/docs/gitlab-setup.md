# Настройка GitLab проекта

Пошаговая инструкция по созданию и настройке проекта `gitlab_ansible` в GitLab.

## 1. Создание проекта

1. Войдите в GitLab
2. **New project → Create blank project**
3. Параметры:
   - **Project name:** `gitlab_ansible`
   - **Project URL:** `infrastructure/gitlab_ansible` (или ваша группа)
   - **Visibility:** Private
   - **Initialize repository:** снять галочку (репозиторий уже локальный)
4. **Create project**

## 2. Push локального репозитория

```bash
cd /path/to/gitlab_ansible

git remote add origin https://gitlab.company.local/infrastructure/gitlab_ansible.git
git add .
git commit -m "Initial commit: unified GitLab CI for Ansible IaC"
git push -u origin main
```

## 3. Настройка CI/CD Variables

**Settings → CI/CD → Variables → Add variable**

| Key | Value | Type | Protected | Masked | Environment |
|---|---|---|---|---|---|
| `ANSIBLE_VAULT_PASSWORD` | `<vault-password>` | Variable | Yes | Yes | All |
| `ANSIBLE_SSH_PRIVATE_KEY` | `<base64-encoded-key>` | Variable | Yes | Yes | All (optional) |

### Ansible Vault

Зашифруйте секреты в inventory:

```bash
ansible-vault encrypt inventories/project-web/group_vars/all/vault.yml
```

CI Variable `ANSIBLE_VAULT_PASSWORD` используется скриптом `ci/scripts/run-ansible.sh`.

## 4. Регистрация shell runner

Следуйте [runner-shell-setup.md](runner-shell-setup.md).

Кратко:

```bash
sudo gitlab-runner register \
  --url "https://gitlab.company.local" \
  --token "<TOKEN>" \
  --executor "shell" \
  --tag-list "ansible-shell"
```

Проверка: **Settings → CI/CD → Runners** — runner online с tag `ansible-shell`.

## 5. Pipeline trigger token

Для запуска из других проектов через API:

1. **Settings → CI/CD → Pipeline triggers → Add trigger**
2. Description: `external-projects`
3. Сохраните token
4. В вызывающих проектах создайте variable `ANSIBLE_TRIGGER_TOKEN` (masked)

## 6. Protected branches

**Settings → Repository → Protected branches**

| Branch | Allowed to merge | Allowed to push | Allowed to deploy |
|---|---|---|---|
| `main` | Maintainers | Maintainers | Maintainers |

Deploy jobs с `when: manual` доступны только Maintainers на protected branch.

## 7. Merge request settings

**Settings → Merge requests**

- Enable **Pipelines must succeed**
- Enable **All threads must be resolved**

Validate stage запускается автоматически на MR.

## 8. Первый запуск pipeline

### Validate (автоматически)

Push в `main` или создание MR → stage `validate` запускается автоматически.

### Deploy (ручной)

1. **CI/CD → Pipelines → Run pipeline**
2. Branch: `main`
3. Variables:

```
TARGET=deploy-web
EXECUTOR=shell
CHECK_MODE=true
```

4. **Run pipeline**
5. Нажмите play (▶) на job `deploy:deploy-web`
6. После завершения: **Browse artifacts → logs/** — проверьте лог

## 9. Настройка Docker runner (опционально)

```bash
sudo gitlab-runner register \
  --url "https://gitlab.company.local" \
  --token "<TOKEN>" \
  --executor "docker" \
  --docker-image "willhallonline/ansible:2.16-alpine" \
  --tag-list "ansible-docker"
```

Запуск с Docker:

```
TARGET=deploy-web
EXECUTOR=docker
```

## 10. Проверочный чеклист

- [ ] Проект создан, код запушен в `main`
- [ ] Shell runner online с tag `ansible-shell`
- [ ] CI Variable `ANSIBLE_VAULT_PASSWORD` добавлена (если используется Vault)
- [ ] Validate pipeline проходит на push/MR
- [ ] Deploy job запускается вручную с `CHECK_MODE=true`
- [ ] Лог сохранён в artifacts (`logs/`)
- [ ] SSH gitlab-runner → target hosts работает
- [ ] Pipeline trigger token создан (для external projects)
- [ ] Protected branch `main` настроен

## 11. Добавление нового playbook (workflow)

1. Создайте feature branch: `git checkout -b feature/add-my-playbook`
2. Добавьте `playbooks/my-playbook/` + `inventories/my-project/`
3. Добавьте job в `ci/templates/ansible-run.yml`
4. Push → создайте MR → validate pipeline
5. После merge — deploy через Run pipeline с `TARGET=my-playbook`

## Связанные документы

- [README](../README.md)
- [Настройка shell runner](runner-shell-setup.md)
- [Запуск из других проектов](external-trigger.md)
