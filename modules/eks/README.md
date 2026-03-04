# modules/eks

Кластер EKS: control plane с управляемым доступом к API, конвертное шифрование Secrets
собственным ключом KMS, OIDC-провайдер для IRSA, managed node groups из карты и
EKS-аддоны.

## Что делает

- создаёт роль control plane и подключает `AmazonEKSClusterPolicy` и
  `AmazonEKSVPCResourceController`;
- создаёт ключ KMS с явной key policy и включает `encryption_config` для `secrets`;
- создаёт log-группу `/aws/eks/<cluster>/cluster` **до** кластера, с заданным retention;
- регистрирует OIDC-издатель кластера как IAM identity provider — это фундамент IRSA;
- создаёт общую роль узлов и группы узлов из карты `node_groups`;
- ставит аддоны из карты `addons` после групп узлов.

## Почему так

**Log-группа создаётся модулем, а не EKS.** Если её не создать заранее, EKS создаёт её при
первой записи с `retention = Never Expire`. Дальше кто-то замечает счёт за CloudWatch через
год, а не через неделю.

**Ключ KMS с явной key policy.** Политика по умолчанию отдаёт полный доступ root аккаунта
и молчит о том, кто ключом пользуется. Явный документ перечисляет ровно троих: администрирование
аккаунта, роль control plane (включая `kms:CreateGrant` — без него кластер поднимается и
падает на первой записи Secret) и сервис CloudWatch Logs с условием на encryption context.

**SPOT требует минимум двух типов инстансов.** Это `validation`, а не рекомендация.
Группа на одном типе инстанса берёт мощность из одного capacity pool; когда AWS забирает
этот пул, уходит вся группа сразу. На четырёх типах уходит четверть.

**`desired_size` в `ignore_changes`.** После создания группы её размером управляет
cluster-autoscaler. Без этого каждый `plan` после автоскейлинга предлагает вернуть группу
к числу, записанному в коде.

**Аддоны зависят от групп узлов.** `coredns` остаётся в состоянии `Degraded`, пока ему
некуда планироваться, а деградировавший аддон роняет `apply`, а не сходится потом сам.

## IRSA, а не instance profile

Роль узла несёт три политики: работа kubelet, чтение из ECR и управление ENI для CNI.
Больше ничего. Всё, что нужно приложению — S3, SQS, Secrets Manager — выдаётся через IRSA:
service account аннотируется ARN роли, доверительная политика роли ссылается на
OIDC-провайдера кластера и на конкретный `system:serviceaccount:<ns>:<name>`.

Разница практическая: право, добавленное в instance profile, получают все поды на узле,
включая тот, который сегодня скомпрометировали. Право, выданное через IRSA, получает
один service account.

```hcl
data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:payments:api"]
    }

    # Без условия на aud роль принимается по токену, выписанному для другой аудитории.
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
```

## Пример

```hcl
module "eks" {
  source = "github.com/lpogosu/terraform-aws-modules//modules/eks?ref=v1.0.0"

  cluster_name       = "platform"
  kubernetes_version = "1.31"
  subnet_ids         = module.network.private_subnet_ids

  endpoint_private_access = true
  endpoint_public_access  = false

  node_groups = {
    system = {
      instance_types = ["m7g.large"]
      ami_type       = "AL2023_ARM_64_STANDARD"
      min_size       = 3
      max_size       = 3
      desired_size   = 3
      taints         = [{ key = "workload", value = "system", effect = "NO_SCHEDULE" }]
    }

    workers = {
      instance_types = ["m7i.large", "m6i.large", "m5.large", "m5a.large"]
      capacity_type  = "SPOT"
      min_size       = 2
      max_size       = 10
      desired_size   = 2
    }
  }

  addons = {
    vpc-cni    = {}
    kube-proxy = {}
    coredns    = {}
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
| [aws_cloudwatch_log_group.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_eks_addon.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_cluster.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) | resource |
| [aws_eks_node_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_node_group) | resource |
| [aws_iam_openid_connect_provider.irsa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kms_alias.secrets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.secrets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| cluster\_name | Name of the EKS cluster. Also the prefix of every IAM role, KMS alias and log group the module creates. | `string` | n/a | yes |
| kubernetes\_version | Kubernetes minor version of the control plane, for example "1.31". Node groups follow it unless they override it. | `string` | n/a | yes |
| subnet\_ids | Subnets the control plane places its cross-account network interfaces in, and the default subnets for node groups. At least two availability zones. | `list(string)` | n/a | yes |
| addons | EKS managed addons, keyed by addon name (`vpc-cni`, `coredns`, `kube-proxy`,<br/>`aws-ebs-csi-driver`). A null `version` lets EKS pick the default for the cluster<br/>version, which is what you want unless you are pinning around a known bug. | <pre>map(object({<br/>    version                     = optional(string)<br/>    service_account_role_arn    = optional(string)<br/>    configuration_values        = optional(string)<br/>    resolve_conflicts_on_create = optional(string, "OVERWRITE")<br/>    resolve_conflicts_on_update = optional(string, "PRESERVE")<br/>    preserve                    = optional(bool, true)<br/>  }))</pre> | `{}` | no |
| authentication\_mode | How the cluster resolves identities: API (EKS access entries), API\_AND\_CONFIG\_MAP, or CONFIG\_MAP (the legacy aws-auth ConfigMap). | `string` | `"API_AND_CONFIG_MAP"` | no |
| bootstrap\_cluster\_creator\_admin\_permissions | Give the principal running apply cluster-admin. Convenient on day one, and an invisible standing grant afterwards. | `bool` | `false` | no |
| cluster\_log\_retention\_days | Retention of /aws/eks/<cluster>/cluster. The module creates this log group itself: left<br/>to EKS it is created with retention set to Never Expire, and audit logs then accumulate<br/>for the lifetime of the account. | `number` | `90` | no |
| cluster\_security\_group\_ids | Extra security groups attached to the control plane network interfaces, on top of the one EKS creates. | `list(string)` | `[]` | no |
| control\_plane\_subnet\_ids | Override the subnets used by the control plane only. Empty list means reuse subnet\_ids. | `list(string)` | `[]` | no |
| create\_kms\_key | Create a customer-managed KMS key for envelope encryption of Kubernetes Secrets. | `bool` | `true` | no |
| enable\_irsa | Register the cluster OIDC issuer as an IAM identity provider so pods can assume roles through service accounts. | `bool` | `true` | no |
| enabled\_cluster\_log\_types | Control plane components whose logs are published to CloudWatch. `audit` and<br/>`authenticator` are the two that answer "who did this"; the rest are for debugging the<br/>control plane itself and are noticeably more expensive. | `list(string)` | <pre>[<br/>  "api",<br/>  "audit",<br/>  "authenticator"<br/>]</pre> | no |
| endpoint\_private\_access | Expose the Kubernetes API on a private endpoint inside the VPC. | `bool` | `true` | no |
| endpoint\_public\_access | Expose the Kubernetes API on a public endpoint. Off by default; turn it on only together with a narrow public\_access\_cidrs. | `bool` | `false` | no |
| kms\_key\_arn | Existing KMS key for envelope encryption. Used when create\_kms\_key is false; null then disables encryption of Secrets entirely. | `string` | `null` | no |
| kms\_key\_deletion\_window\_days | Waiting period before a scheduled key deletion takes effect. Deleting the key makes every Secret in etcd unreadable, so the window is the last chance to notice. | `number` | `30` | no |
| node\_groups | Managed node groups, keyed by name. The key becomes the node group name, so it is part<br/>of the resource address in state: renaming a key replaces the group.<br/><br/>`capacity_type = "SPOT"` requires more than one instance type. A SPOT group pinned to a<br/>single type draws from a single capacity pool, and when that pool is reclaimed every<br/>node in the group goes at once. | <pre>map(object({<br/>    subnet_ids         = optional(list(string), [])<br/>    instance_types     = optional(list(string), ["t3.large"])<br/>    capacity_type      = optional(string, "ON_DEMAND")<br/>    ami_type           = optional(string, "AL2023_x86_64_STANDARD")<br/>    disk_size          = optional(number, 50)<br/>    kubernetes_version = optional(string)<br/>    min_size           = number<br/>    max_size           = number<br/>    desired_size       = number<br/>    max_unavailable    = optional(number, 1)<br/>    labels             = optional(map(string), {})<br/>    taints = optional(list(object({<br/>      key    = string<br/>      value  = optional(string)<br/>      effect = string<br/>    })), [])<br/>    tags = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| node\_role\_additional\_policy\_arns | Extra managed policies for the shared node role, beyond the three EKS requires. Prefer IRSA over adding anything here. | `list(string)` | `[]` | no |
| public\_access\_cidrs | Source ranges allowed to reach the public endpoint. Ignored while endpoint\_public\_access is false. | `list(string)` | `[]` | no |
| service\_ipv4\_cidr | CIDR the cluster allocates Service IPs from. Null lets EKS pick 172.20.0.0/16, which collides with a surprising number of corporate networks. | `string` | `null` | no |
| tags | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| addon\_versions | Resolved version of each managed addon. |
| cluster\_arn | ARN of the EKS cluster. |
| cluster\_certificate\_authority\_data | Base64 PEM of the cluster CA, for the certificate-authority-data field of a kubeconfig. |
| cluster\_endpoint | HTTPS endpoint of the Kubernetes API server. |
| cluster\_iam\_role\_arn | ARN of the control plane IAM role. |
| cluster\_name | Name of the EKS cluster. |
| cluster\_security\_group\_id | Security group EKS created for the control plane. Node groups are placed in it automatically. |
| cluster\_version | Kubernetes version the control plane is actually running. |
| kubeconfig\_command | Command that writes a kubeconfig entry for this cluster. |
| node\_group\_arns | Node group ARNs keyed by node group name. |
| node\_group\_capacity\_types | Capacity type of each node group. Useful in a review: it shows at a glance what is running on SPOT. |
| node\_iam\_role\_arn | ARN of the shared node instance role. |
| node\_iam\_role\_name | Name of the shared node instance role. Needed to create an EKS access entry for the nodes under authentication\_mode = API. |
| oidc\_issuer\_host | OIDC issuer without the scheme. This is the prefix of the sub and aud condition keys in an IRSA trust policy. |
| oidc\_issuer\_url | OIDC issuer URL of the cluster. |
| oidc\_provider\_arn | ARN of the IAM OIDC provider backing IRSA, or null when IRSA is disabled. This is the Federated principal of every IRSA role. |
| secrets\_kms\_key\_arn | KMS key used for envelope encryption of Secrets, or null when encryption is disabled. |
<!-- END_TF_DOCS -->
