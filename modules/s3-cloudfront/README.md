# modules/s3-cloudfront

Закрытый бакет S3 как origin и дистрибутив CloudFront перед ним, связанные через Origin
Access Control. Версионирование, lifecycle, шифрование, блокировка публичного доступа и
опциональный бакет логов.

## Что делает

- создаёт бакет origin с полной блокировкой публичного доступа и `BucketOwnerEnforced`;
- включает версионирование, шифрование (SSE-S3 или SSE-KMS) и правила lifecycle;
- создаёт Origin Access Control и дистрибутив с одним S3-origin;
- пишет bucket policy, разрешающую чтение только сервису CloudFront и только для этого
  дистрибутива;
- по запросу создаёт второй бакет под стандартные access-логи CloudFront.

## Origin Access Control, а не OAI

Origin Access Identity — механизм 2014 года: CloudFront получает виртуального пользователя,
которому бакет выдаёт права через ACL или policy. AWS перевёл OAI в статус legacy и не
добавляет к нему ничего нового.

Origin Access Control подписывает каждый запрос к origin по SigV4. Практическая разница:

- **SSE-KMS работает.** OAI не умеет подписывать запрос так, чтобы S3 отдал объект,
  зашифрованный ключом KMS. С OAI приходится либо шифровать SSE-S3, либо отказываться
  от приватного origin.
- **Методы, кроме GET и HEAD.** OAI ограничен чтением.
- **Условие в policy указывает на дистрибутив, а не на пользователя.** `AWS:SourceArn`
  сужает доступ до одного конкретного дистрибутива. У OAI аналога нет: любой дистрибутив,
  которому назначен тот же OAI, читает бакет.

Bucket policy в модуле содержит ровно два statement: чтение сервисом
`cloudfront.amazonaws.com` с условием `AWS:SourceArn` на ARN дистрибутива и явный `Deny`
на всё при `aws:SecureTransport = false`.

## Почему так

**`bucket_regional_domain_name`, а не `bucket_domain_name`.** Глобальный эндпоинт S3
отвечает редиректом 307 на региональный для бакета моложе суток. Подписанный запрос
редирект не переживает, и дистрибутив первые часы после создания отдаёт ошибки.

**Точка в имени бакета запрещена валидацией.** Wildcard-сертификат на
`*.s3.<region>.amazonaws.com` покрывает один уровень имени. Бакет `assets.example.com`
через CloudFront работать не будет, и диагностируется это как TLS-ошибка от origin.

**Бакет логов отличается от origin в трёх местах.** Доставка стандартных логов CloudFront
до сих пор пишет через ACL-грант каноническому пользователю `awslogsdelivery`. Поэтому у
него `BucketOwnerPreferred` вместо `BucketOwnerEnforced` и SSE-S3 вместо SSE-KMS: с
`BucketOwnerEnforced` или с ключом KMS логи просто перестают приходить, и нигде не
появляется сообщение об ошибке. Третье отличие — собственный lifecycle: без него логи
копятся вечно.

**Правило lifecycle обязано что-то делать.** Правило без единого действия S3 принимает,
показывает как `Enabled` и не удаляет ничего. Валидация требует хотя бы одно действие и
запрещает transition, назначенный не раньше expiration.

## Пример

```hcl
module "frontend" {
  source = "github.com/lpogosu/terraform-aws-modules//modules/s3-cloudfront?ref=v1.0.0"

  bucket_name = "example-shop-frontend-0000"

  aliases             = ["shop.example.com"]
  acm_certificate_arn = aws_acm_certificate.shop.arn # обязательно в us-east-1

  custom_error_responses = {
    "403" = { response_code = 200, response_page_path = "/index.html" }
    "404" = { response_code = 200, response_page_path = "/index.html" }
  }

  lifecycle_rules = {
    expire-old-bundles = {
      noncurrent_version_expiration_days = 30
      abort_incomplete_multipart_days    = 7
    }
  }

  enable_logging = true
}
```

Деплой — синхронизация плюс инвалидация; вторую забывают чаще, чем первую:

```bash
aws s3 sync ./dist "s3://$(terraform output -raw site_bucket)" --delete
aws cloudfront create-invalidation \
  --distribution-id "$(terraform output -raw distribution_id)" --paths '/*'
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
| [aws_cloudfront_distribution.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution) | resource |
| [aws_cloudfront_origin_access_control.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_origin_access_control) | resource |
| [aws_s3_bucket.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.origin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.origin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_ownership_controls.origin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.origin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.origin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.origin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_bucket_versioning.origin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| bucket\_name | Name of the origin bucket. Globally unique across all AWS accounts. | `string` | n/a | yes |
| acm\_certificate\_arn | ACM certificate for the aliases. Must live in us-east-1: CloudFront reads certificates from that region only, whatever region the rest of the stack is in. | `string` | `null` | no |
| aliases | Alternate domain names served by the distribution. Requires acm\_certificate\_arn. | `list(string)` | `[]` | no |
| cache\_policy\_id | Cache policy for the default behaviour. Null looks up the AWS managed CachingOptimized policy. | `string` | `null` | no |
| custom\_error\_responses | Error responses rewritten at the edge, keyed by the status code CloudFront received.<br/>A single-page application maps 403 and 404 to /index.html with response code 200;<br/>without that, a deep link reloads into an S3 error document. | <pre>map(object({<br/>    response_code         = number<br/>    response_page_path    = string<br/>    error_caching_min_ttl = optional(number, 10)<br/>  }))</pre> | `{}` | no |
| default\_root\_object | Object returned for a request to the distribution root. | `string` | `"index.html"` | no |
| enable\_logging | Create a second bucket and send CloudFront standard access logs to it. | `bool` | `false` | no |
| force\_destroy | Allow `terraform destroy` to delete a bucket that still holds objects. Off by default. | `bool` | `false` | no |
| geo\_restriction\_locations | ISO 3166-1 alpha-2 country codes the restriction applies to. | `list(string)` | `[]` | no |
| geo\_restriction\_type | Geographic restriction: none, whitelist or blacklist. | `string` | `"none"` | no |
| kms\_key\_arn | KMS key encrypting objects at rest. Null uses SSE-S3 (AES256).<br/><br/>SSE-KMS on a CloudFront origin means every cache miss is a KMS Decrypt call, billed and<br/>rate limited. It is the right choice for private data and the wrong one for a public<br/>static site, which is why the module does not pick for you. | `string` | `null` | no |
| lifecycle\_rules | Lifecycle rules, keyed by rule ID. Every rule must actually do something: a rule with<br/>no transition and no expiry is accepted by S3, shows up as enabled, and deletes nothing.<br/><br/>`noncurrent_version_expiration_days` is the one that matters on a versioned bucket.<br/>Without it, every overwritten object is kept forever and the bill grows in a line item<br/>nobody looks at. | <pre>map(object({<br/>    prefix                             = optional(string, "")<br/>    enabled                            = optional(bool, true)<br/>    abort_incomplete_multipart_days    = optional(number)<br/>    expiration_days                    = optional(number)<br/>    noncurrent_version_expiration_days = optional(number)<br/>    noncurrent_versions_to_keep        = optional(number)<br/>    transitions = optional(list(object({<br/>      days          = number<br/>      storage_class = string<br/>    })), [])<br/>    noncurrent_version_transitions = optional(list(object({<br/>      days          = number<br/>      storage_class = string<br/>    })), [])<br/>  }))</pre> | `{}` | no |
| log\_bucket\_name | Name of the log bucket. Null derives it from bucket\_name. | `string` | `null` | no |
| log\_retention\_days | Days access logs are kept before the lifecycle rule expires them. | `number` | `90` | no |
| minimum\_protocol\_version | Lowest TLS version accepted from viewers. Only applies while a custom certificate is attached. | `string` | `"TLSv1.2_2021"` | no |
| price\_class | Edge locations the distribution uses: PriceClass\_100 (NA + EU), PriceClass\_200 (adds Asia), PriceClass\_All. | `string` | `"PriceClass_100"` | no |
| response\_headers\_policy\_id | Response headers policy, for HSTS and the other security headers. Null looks up the AWS managed SecurityHeadersPolicy. | `string` | `null` | no |
| tags | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |
| versioning\_enabled | Keep previous versions of every object. This is what makes a bad deploy recoverable without a backup job. | `bool` | `true` | no |
| web\_acl\_id | ARN of a WAFv2 web ACL to attach. The ACL must be created in us-east-1 with scope CLOUDFRONT. | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| bucket\_arn | ARN of the origin bucket. Grant the deploy role s3:PutObject on "<arn>/*". |
| bucket\_id | Name of the origin bucket. |
| bucket\_regional\_domain\_name | Regional endpoint of the origin bucket, which is what CloudFront is pointed at. |
| deploy\_commands | Sync the site and invalidate the edge caches. The invalidation is the step people forget. |
| distribution\_arn | ARN of the distribution. The origin bucket policy is scoped to exactly this value. |
| distribution\_domain\_name | The <id>.cloudfront.net name of the distribution. |
| distribution\_hosted\_zone\_id | Hosted zone ID of the distribution, for a Route 53 alias record. |
| distribution\_id | CloudFront distribution ID. This is the argument of `aws cloudfront create-invalidation`. |
| log\_bucket\_id | Name of the access log bucket, or null when logging is disabled. |
| origin\_access\_control\_id | ID of the Origin Access Control signing the origin requests. |
<!-- END_TF_DOCS -->
