# modules/rds

Инстанс RDS PostgreSQL: автомасштабирование диска, Multi-AZ, группа подсетей, группа
параметров, окна бэкапа и обслуживания, Performance Insights, enhanced monitoring и
пароль мастера в Secrets Manager.

## Что делает

- создаёт группу подсетей, группу параметров и security-группу без единого egress-правила;
- создаёт роль enhanced monitoring, если `monitoring_interval` не ноль;
- создаёт инстанс с `manage_master_user_password = true`.

## Пароль не проходит через Terraform

`manage_master_user_password = true` — RDS сам генерирует пароль, кладёт его в Secrets
Manager и там же ротирует. Модуль не принимает пароль на вход, не пишет его в state и не
выводит. В state попадает только ARN секрета.

Альтернатива, которая встречается чаще: `random_password` + `aws_secretsmanager_secret_version`.
Она выглядит так же аккуратно, но пароль при этом лежит в открытом виде в state — сначала
в ресурсе `random_password`, потом в версии секрета. То, что Terraform помечает атрибут
`sensitive`, влияет только на вывод в терминал; в файле состояния значение обычное.

```bash
export PGPASSWORD="$(aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw database_secret_arn)" \
  --query SecretString --output text | jq -r .password)"
```

Приложению выдаётся `secretsmanager:GetSecretValue` на этот ARN — через IRSA, если оно
живёт в EKS.

## Почему так

**Модуль ставит инстанс в intra-подсети.** Валидация требует минимум двух зон даже для
Single-AZ: группа подсетей — это то, что делает переход на Multi-AZ и восстановление из
снапшота вопросом одной переменной, а не переездом.

**`rds.force_ssl = 1` зашит, а не вынесен в переменную.** Параметр статический: если
обнаружить его отсутствие потом, включение стоит перезагрузки инстанса. Конфигурации, при
которой PostgreSQL внутри VPC обязан принимать открытые соединения, не существует.

**Окна бэкапа и обслуживания проверяются на пересечение.** RDS такое сочетание отвергает,
но узнаёт об этом через несколько минут после начала создания инстанса. Валидация
переводит оба окна в минуты от полуночи и сравнивает интервалы.

**Нет ни одного egress-правила.** База данных — сервер: она отвечает на соединения и не
открывает их. Пустой набор egress — это конфигурация, а не забытая строка.

**Имя финального снапшота можно задать.** По умолчанию берётся `<identifier>-final`.
Для окружения, которое поднимают и сносят регулярно, это грабли: RDS отказывается создать
снапшот с уже существующим именем, и второй `destroy` того же идентификатора падает на
последнем шаге, когда всё остальное уже удалено. Для таких окружений либо задаётся
`final_snapshot_identifier`, либо ставится `skip_final_snapshot = true`.

**`deletion_protection` по умолчанию `true`.** Компромисс осознанный: снести временное
окружение теперь нельзя одной командой, надо сначала явно передать `false`. Цена ошибки
в другую сторону — удалённый прод.

## Пример

```hcl
module "database" {
  source = "github.com/lpogosu/terraform-aws-modules//modules/rds?ref=v1.0.0"

  identifier = "shop-pg"
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.intra_subnet_ids

  engine_version         = "16"
  parameter_group_family = "postgres16"
  instance_class         = "db.m7g.large"

  allocated_storage     = 100
  max_allocated_storage = 500
  multi_az              = true

  allowed_security_group_ids = [aws_security_group.app.id]

  backup_retention_period = 14
  backup_window           = "01:00-02:00"
  maintenance_window      = "sun:03:00-sun:05:00"

  parameters = {
    "log_min_duration_statement" = { value = "1000" }
    "pg_stat_statements.max"     = { value = "5000", apply_method = "pending-reboot" }
  }
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.9.0, < 2.0.0 |
| aws | ~> 5.70 |

## Providers

| Name | Version |
|------|---------|
| aws | ~> 5.70 |

## Resources

| Name | Type |
|------|------|
| [aws_db_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_parameter_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_parameter_group) | resource |
| [aws_db_subnet_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_iam_role.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_ingress_rule.from_cidr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.from_security_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| engine\_version | PostgreSQL version. A major-only value such as "16" tracks the latest minor and lets AWS upgrade it inside the maintenance window. | `string` | n/a | yes |
| identifier | DB instance identifier. Also the prefix of the subnet group, parameter group and security group. | `string` | n/a | yes |
| instance\_class | RDS instance class, for example db.t4g.medium or db.m7g.large. | `string` | n/a | yes |
| parameter\_group\_family | Parameter group family, for example postgres16. Must match the major version of engine\_version. | `string` | n/a | yes |
| subnet\_ids | Subnets of the DB subnet group. Use the intra subnets: an RDS instance has no reason to reach the internet. | `list(string)` | n/a | yes |
| vpc\_id | VPC the security group is created in. | `string` | n/a | yes |
| allocated\_storage | Initial storage in GiB. | `number` | `50` | no |
| allowed\_cidr\_blocks | CIDR blocks allowed to connect to the database port. Use sparingly; a security group reference survives a re-addressing of the network, a CIDR does not. | `list(string)` | `[]` | no |
| allowed\_security\_group\_ids | Security groups allowed to connect to the database port. This is the intended way in: application security group in, everything else out. | `list(string)` | `[]` | no |
| apply\_immediately | Apply changes now instead of waiting for the maintenance window. Some of them restart the instance. | `bool` | `false` | no |
| auto\_minor\_version\_upgrade | Let RDS apply minor version upgrades inside the maintenance window. | `bool` | `true` | no |
| backup\_retention\_period | Days of automated backups. Zero disables them, and with them point-in-time recovery. | `number` | `14` | no |
| backup\_window | Daily window for the backup snapshot, UTC, as hh:mm-hh:mm. | `string` | `"01:00-02:00"` | no |
| database\_name | Name of the database created on first boot. | `string` | `"app"` | no |
| deletion\_protection | Refuse to delete the instance until this is turned off. Defaults to true: an accidental<br/>`terraform destroy` against the wrong workspace is the failure this exists for.<br/>Ephemeral environments should pass false explicitly, so the choice is visible in the diff. | `bool` | `true` | no |
| enabled\_cloudwatch\_logs\_exports | PostgreSQL log types shipped to CloudWatch: postgresql (the server log) and upgrade. | `list(string)` | <pre>[<br/>  "postgresql",<br/>  "upgrade"<br/>]</pre> | no |
| final\_snapshot\_identifier | Name of the snapshot taken on destroy. Null derives `<identifier>-final`.<br/><br/>Worth setting explicitly on an environment that is created and destroyed repeatedly:<br/>RDS refuses to create a snapshot whose name already exists, so the second destroy of<br/>the same identifier fails at the very end of the operation, with everything else<br/>already gone. | `string` | `null` | no |
| maintenance\_window | Weekly window for minor version upgrades and OS patching, UTC, as ddd:hh:mm-ddd:hh:mm. | `string` | `"sun:03:00-sun:05:00"` | no |
| master\_user\_secret\_kms\_key\_id | Customer-managed KMS key encrypting the master password secret. Null uses the aws/secretsmanager AWS-managed key. | `string` | `null` | no |
| master\_username | Master user name. The password is generated by RDS and stored in Secrets Manager; it is never an input to this module. | `string` | `"postgres"` | no |
| max\_allocated\_storage | Ceiling for storage autoscaling in GiB. Null disables autoscaling, which means the<br/>instance stops accepting writes the moment the volume fills. | `number` | `200` | no |
| monitoring\_interval | Enhanced monitoring granularity in seconds: 0 (off), 1, 5, 10, 15, 30 or 60. The module creates the monitoring role when this is not zero. | `number` | `60` | no |
| multi\_az | Run a synchronous standby in a second availability zone. Roughly doubles the instance cost and turns a zone failure into a ~60 second failover. | `bool` | `false` | no |
| parameters | Database parameters, keyed by parameter name. `apply_method` is `immediate` for dynamic<br/>parameters and `pending-reboot` for static ones; getting it wrong makes the parameter<br/>look applied while the server is still running the old value. | <pre>map(object({<br/>    value        = string<br/>    apply_method = optional(string, "immediate")<br/>  }))</pre> | `{}` | no |
| performance\_insights\_enabled | Collect Performance Insights. The 7-day tier is free and is the difference between diagnosing a slow query and guessing at one. | `bool` | `true` | no |
| performance\_insights\_retention\_period | Days of Performance Insights history: 7 (free), 731, or a multiple of 31 up to 731. | `number` | `7` | no |
| port | TCP port the instance listens on. | `number` | `5432` | no |
| skip\_final\_snapshot | Delete the instance without taking a final snapshot. Only reasonable when the data is reproducible. | `bool` | `false` | no |
| storage\_kms\_key\_id | KMS key encrypting the storage volume, snapshots and Performance Insights data. Null uses the aws/rds AWS-managed key. | `string` | `null` | no |
| storage\_type | EBS volume type backing the instance: gp3 for almost everything, io2 when a specific IOPS number is contractual. | `string` | `"gp3"` | no |
| tags | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| address | DNS name of the instance without the port. |
| database\_name | Name of the database created on first boot. |
| endpoint | Host and port to connect to, as host:port. |
| instance\_arn | ARN of the DB instance. |
| instance\_id | Identifier of the DB instance. |
| instance\_resource\_id | Immutable resource ID of the instance. This is what an rds-db:connect IAM policy names, not the identifier. |
| master\_user\_secret\_arn | ARN of the Secrets Manager secret RDS manages the master password in. Grant the application secretsmanager:GetSecretValue on this. |
| master\_username | Master user name. The password lives in Secrets Manager and is not exposed here. |
| monitoring\_role\_arn | ARN of the enhanced monitoring role, or null when monitoring\_interval is zero. |
| parameter\_group\_name | Name of the parameter group attached to the instance. |
| port | Port the instance listens on. |
| psql\_command | Command that reads the master password out of Secrets Manager and opens a psql session. |
| security\_group\_id | Security group in front of the instance. Reference it from the application security group rather than widening it here. |
| subnet\_group\_name | Name of the DB subnet group. |
<!-- END_TF_DOCS -->
