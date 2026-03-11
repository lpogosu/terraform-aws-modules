# modules/network

VPC с тремя уровнями подсетей по зонам доступности, интернет-шлюзом, NAT-шлюзами,
таблицами маршрутизации, flow-логами в CloudWatch и обезвреженной security-группой
по умолчанию.

## Что делает

- создаёт `aws_vpc` и по одной подсети каждого уровня на каждую зону из `azs`;
- поднимает интернет-шлюз, если запрошены публичные подсети;
- создаёт NAT-шлюзы — по одному на зону или один на всю VPC, переключателем
  `single_nat_gateway`;
- даёт приватным подсетям таблицу маршрутизации на зону, intra-подсетям — общую таблицу
  вообще без маршрута по умолчанию;
- включает flow-логи с ролью, которой разрешено писать только в созданную log-группу;
- забирает под управление security-группу по умолчанию и снимает с неё все правила.

## Три уровня подсетей

| Уровень | Маршрут по умолчанию | Для чего |
|---|---|---|
| `public` | интернет-шлюз | ALB/NLB, NAT-шлюзы |
| `private` | NAT-шлюз | узлы EKS, инстансы приложения |
| `intra` | нет вообще | RDS, ElastiCache, VPC-эндпоинты |

Intra-подсеть — не «приватная с более строгой SG». В её таблице маршрутизации нет записи
`0.0.0.0/0`: скомпрометированный процесс не может открыть исходящее соединение, потому что
маршрута наружу физически нет. Security-группу можно случайно расширить в PR на три строки,
маршрут — нельзя.

## Почему так

**Подсети адресуются зоной, а не индексом.** Ключ `for_each` попадает в адрес ресурса:
`aws_subnet.private["eu-central-1b"]`. При переходе на список с `count` удаление зоны
из середины сдвинуло бы индексы, и Terraform запланировал бы пересоздание всех подсетей
после неё — вместе с ENI, которые в них живут.

**Таблиц маршрутизации всегда по одной на зону, даже при `single_nat_gateway = true`.**
Таблица стоит ноль. Если бы при одном NAT-шлюзе создавалась одна общая таблица,
переключение `single_nat_gateway` в `false` уничтожало бы таблицы и ассоциации и создавало
новые; при неизменной топологии меняется только цель маршрута.

**Роль flow-логов ограничена одной log-группой.** В документации AWS в этом месте стоит
`logs:*` на `*`. Роль, которую может принять сервис, с правом писать в любую log-группу
аккаунта — это способ затереть чужой аудит-лог.

**`aws_default_security_group` без правил.** Группа по умолчанию создаётся вместе с VPC,
удалить её нельзя, и она разрешает любой трафик между своими участниками. Инстанс,
запущенный без явно указанной группы, попадает именно в неё. Единственный способ сделать
такой инстанс изолированным — забрать группу под управление Terraform и оставить пустой.

## Пример

```hcl
module "network" {
  source = "github.com/lpogosu/terraform-aws-modules//modules/network?ref=v1.0.0"

  name       = "prod"
  cidr_block = "10.10.0.0/16"
  azs        = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

  public_subnet_cidrs  = ["10.10.0.0/20", "10.10.16.0/20", "10.10.32.0/20"]
  private_subnet_cidrs = ["10.10.64.0/20", "10.10.80.0/20", "10.10.96.0/20"]
  intra_subnet_cidrs   = ["10.10.128.0/24", "10.10.129.0/24", "10.10.130.0/24"]

  single_nat_gateway = false

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
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
| [aws_cloudwatch_log_group.flow_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_default_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_security_group) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_flow_log.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/flow_log) | resource |
| [aws_iam_role.flow_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.flow_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_route.private_default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route.public_default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.intra](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.intra](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_subnet.intra](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| azs | Availability zone names to spread the subnets over, for example ["eu-central-1a", "eu-central-1b"]. | `list(string)` | n/a | yes |
| cidr\_block | IPv4 CIDR block of the VPC. | `string` | n/a | yes |
| name | Prefix for every resource name and the Name tag of the VPC. | `string` | n/a | yes |
| enable\_dns\_hostnames | Assign public DNS hostnames to instances with a public IP. Required by EKS and by RDS private endpoints. | `bool` | `true` | no |
| enable\_flow\_logs | Ship VPC flow logs to a CloudWatch log group created by this module. | `bool` | `true` | no |
| enable\_nat\_gateway | Create NAT gateways so the private subnets can make outbound connections. | `bool` | `true` | no |
| flow\_log\_kms\_key\_arn | Customer-managed KMS key encrypting the flow log group. Null leaves CloudWatch on its<br/>service-managed key, which is still encryption at rest but not one you can revoke. | `string` | `null` | no |
| flow\_log\_max\_aggregation\_interval | Seconds a flow is aggregated before being published: 60 or 600. 60 costs more and shows short-lived connections. | `number` | `600` | no |
| flow\_log\_retention\_days | Retention of the flow log group. Must be one of the values CloudWatch accepts. | `number` | `90` | no |
| flow\_log\_traffic\_type | Which flows to record: ACCEPT, REJECT or ALL. | `string` | `"ALL"` | no |
| intra\_subnet\_cidrs | CIDR blocks for the intra subnets, one per entry of `azs` and in the same order.<br/>Intra subnets get a route table with no default route at all: nothing in them can reach<br/>the internet, and nothing on the internet can reach them. Databases and cache clusters<br/>belong here. | `list(string)` | `[]` | no |
| intra\_subnet\_tags | Extra tags for the intra subnets only. | `map(string)` | `{}` | no |
| manage\_default\_security\_group | Adopt the security group AWS creates with the VPC and strip every rule from it.<br/>The default group allows unrestricted traffic between its own members, and anything<br/>launched without an explicit group lands in it. | `bool` | `true` | no |
| map\_public\_ip\_on\_launch | Give every instance launched into a public subnet a public IPv4 address automatically.<br/>Off by default: load balancers and NAT gateways bring their own addresses, so turning<br/>this on mostly hands public IPs to instances that were never meant to have one. | `bool` | `false` | no |
| private\_subnet\_cidrs | CIDR blocks for the private subnets, one per entry of `azs` and in the same order.<br/>These are the subnets that reach the internet through NAT. | `list(string)` | `[]` | no |
| private\_subnet\_tags | Extra tags for the private subnets only. EKS discovers internal load balancer subnets through kubernetes.io/role/internal-elb. | `map(string)` | `{}` | no |
| public\_subnet\_cidrs | CIDR blocks for the public subnets, one per entry of `azs` and in the same order.<br/>An empty list creates no public subnets, and with them no internet gateway and no NAT. | `list(string)` | `[]` | no |
| public\_subnet\_tags | Extra tags for the public subnets only. EKS discovers internet-facing load balancer subnets through kubernetes.io/role/elb. | `map(string)` | `{}` | no |
| single\_nat\_gateway | Put one NAT gateway in the first availability zone and route every private subnet<br/>through it, instead of one gateway per zone. Cuts the hourly charge to 1/N, and makes<br/>the loss of that one zone an outage for every private subnet. Non-production only. | `bool` | `false` | no |
| tags | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| azs | Availability zones the subnets are spread over. |
| default\_security\_group\_id | ID of the VPC default security group. All of its rules are removed when manage\_default\_security\_group is true. |
| flow\_log\_group\_arn | ARN of the CloudWatch log group receiving flow logs, or null when flow logs are disabled. |
| flow\_log\_group\_name | Name of the CloudWatch log group receiving flow logs, or null when flow logs are disabled. |
| internet\_gateway\_id | ID of the internet gateway, or null when no public subnet exists. |
| intra\_route\_table\_id | ID of the shared intra route table, or null when no intra subnet exists. |
| intra\_subnet\_cidrs | IPv4 CIDR blocks of the intra subnets, keyed by availability zone. |
| intra\_subnet\_ids | Intra subnet IDs in the order of var.azs. No route to the internet in either direction. |
| intra\_subnets\_by\_az | Intra subnet IDs keyed by availability zone. |
| nat\_gateway\_ids | NAT gateway IDs keyed by the availability zone they sit in. Empty when NAT is disabled. |
| nat\_public\_ips | Elastic IPs of the NAT gateways. These are the source addresses partners have to allow-list. |
| private\_route\_table\_ids | Private route table IDs keyed by availability zone. Needed to attach S3 and DynamoDB gateway endpoints. |
| private\_subnet\_cidrs | IPv4 CIDR blocks of the private subnets, keyed by availability zone. |
| private\_subnet\_ids | Private subnet IDs in the order of var.azs. Suitable for EKS nodes and application instances. |
| private\_subnets\_by\_az | Private subnet IDs keyed by availability zone. |
| public\_route\_table\_id | ID of the shared public route table, or null when no public subnet exists. |
| public\_subnet\_cidrs | IPv4 CIDR blocks of the public subnets, keyed by availability zone. |
| public\_subnet\_ids | Public subnet IDs in the order of var.azs. Suitable for internet-facing load balancers. |
| public\_subnets\_by\_az | Public subnet IDs keyed by availability zone. |
| vpc\_arn | ARN of the VPC. |
| vpc\_cidr\_block | IPv4 CIDR block of the VPC. |
| vpc\_id | ID of the VPC. |
<!-- END_TF_DOCS -->
