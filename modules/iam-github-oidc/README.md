# modules/iam-github-oidc

OIDC-провайдер GitHub Actions и роль, которую можно принять только из перечисленных
репозиториев, веток и окружений.

## Что делает

- регистрирует `token.actions.githubusercontent.com` как IAM identity provider
  (или принимает ARN уже существующего — провайдер в аккаунте может быть только один);
- собирает доверительную политику из карты `repositories`;
- вешает на роль inline-политику из типизированных statement'ов и, если нужно, managed-политики.

## Как выглядит доверие

GitHub кладёт в токен claim `sub` вида:

```
repo:<owner>/<name>:ref:refs/heads/main
repo:<owner>/<name>:environment:production
repo:<owner>/<name>:pull_request
```

Доверительная политика сравнивается именно с этой строкой. Карта `repositories`
разворачивается в список таких строк, и список — это всё управление доступом к роли:
ничто дальше в пайплайне его расширить не может. Точный список виден в выходе
`trusted_subjects`, чтобы в ревью читать его, а не декодировать JSON политики.

Модуль запрещает три вещи:

| Запрет | Что происходит без него |
|---|---|
| `*` вместо `owner/name` | роль принимает любой репозиторий на GitHub |
| `refs/*` или `*` в списке ref | роль принимает любую ветку, включая только что созданную атакующим |
| репозиторий без единого claim | доверительная политика заканчивается на `repo:owner/name:*` |

Условие на `aud` ставится всегда. Без него роль принимается по токену, выписанному для
любой другой аудитории.

## Почему OIDC, а не ключи доступа

`AWS_ACCESS_KEY_ID` в секретах репозитория — это долгоживущий пароль. Он не истекает,
ротацию делает человек, а утечка обнаруживается по счёту за майнинг. Отозвать его можно
только вручную, и до этого момента он работает откуда угодно.

OIDC-токен выписывается на конкретный запуск конкретного workflow, живёт минуты и
принимается только для тех `sub`, что перечислены в политике. Ротировать нечего.
Утечка из лога workflow бессмысленна к моменту, когда её найдут.

Отдельно: с ключом «кто может деплоить» решается настройками секретов репозитория, а
это видит только администратор GitHub. С OIDC это решается доверительной политикой роли,
которая лежит в Terraform и проходит через ревью вместе с остальным кодом.

## Thumbprint не пинуется

`thumbprint_list` по умолчанию пуст, и провайдер AWS сам получает актуальный отпечаток.
Захардкоженный отпечаток из чужого блог-поста — это отложенная поломка: когда GitHub
меняет промежуточный CA, аутентификация перестаёт работать во всех пайплайнах разом.

## Пример

```hcl
module "ci_role" {
  source = "github.com/lpogosu/terraform-aws-modules//modules/iam-github-oidc?ref=v1.0.0"

  role_name = "platform-github-deploy"

  repositories = {
    "lpogosu/terraform-aws-modules" = {
      refs         = ["refs/heads/main"]
      environments = ["production"]
    }
  }

  max_session_duration = 3600

  policy_statements = [{
    sid       = "PushArtifacts"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::example-shop-frontend-0000/*"]
  }]
}
```

В workflow:

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@v4.0.2
    with:
      role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
      aws-region: eu-central-1
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
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.inline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| repositories | Repositories allowed to assume the role, keyed by `owner/name`. Each entry lists the<br/>claims that are accepted, and at least one of them must be non-empty:<br/><br/>  refs         - `refs/heads/main`, `refs/tags/v*`; matched against the `ref` subject<br/>  environments - GitHub Environment names; use these when the environment has reviewers<br/>  pull\_request - accept the synthetic `pull_request` subject of a PR-triggered run<br/><br/>Wildcards are allowed inside a claim but the claim itself is never optional: a role<br/>whose trust policy ends at `repo:owner/name:*` is assumable from any branch, and any<br/>branch includes the one an attacker just pushed. | <pre>map(object({<br/>    refs         = optional(list(string), [])<br/>    environments = optional(list(string), [])<br/>    pull_request = optional(bool, false)<br/>  }))</pre> | n/a | yes |
| role\_name | Name of the IAM role GitHub Actions assumes. | `string` | n/a | yes |
| audience | Value the aud claim must carry. Leave at sts.amazonaws.com unless the workflow overrides the audience when requesting its token. | `string` | `"sts.amazonaws.com"` | no |
| create\_oidc\_provider | Create the token.actions.githubusercontent.com identity provider. There can be only one<br/>per AWS account, so set this to false and pass `oidc_provider_arn` in every account that<br/>already has it. | `bool` | `true` | no |
| managed\_policy\_arns | Customer or AWS managed policies attached to the role in addition to the inline statements. | `list(string)` | `[]` | no |
| max\_session\_duration | Ceiling on how long the credentials the workflow receives stay valid, in seconds.<br/>IAM's floor for a role is one hour - 900 seconds is the floor of the AssumeRole call,<br/>not of the role - so a shorter session is requested by the caller, not configured here. | `number` | `3600` | no |
| oidc\_provider\_arn | ARN of an existing GitHub OIDC provider. Required when create\_oidc\_provider is false, ignored otherwise. | `string` | `null` | no |
| oidc\_thumbprints | Certificate thumbprints of the GitHub OIDC endpoint. Leave empty: since provider 5.x<br/>Terraform fetches the current thumbprint itself, and a hardcoded one silently expires<br/>when GitHub rotates its intermediate CA. | `list(string)` | `[]` | no |
| permissions\_boundary | Optional permissions boundary policy ARN. A ceiling the role cannot exceed even if its own policy is widened later. | `string` | `null` | no |
| policy\_statements | Inline policy the role carries. Written as statements rather than raw JSON so the<br/>module can refuse an obviously over-broad one before it reaches IAM. | <pre>list(object({<br/>    sid       = string<br/>    effect    = optional(string, "Allow")<br/>    actions   = list(string)<br/>    resources = list(string)<br/>    conditions = optional(list(object({<br/>      test     = string<br/>      variable = string<br/>      values   = list(string)<br/>    })), [])<br/>  }))</pre> | `[]` | no |
| tags | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| oidc\_provider\_arn | ARN of the GitHub OIDC provider, whether this module created it or it was passed in. |
| role\_arn | ARN of the role. This is the value that goes into role-to-assume in the workflow. |
| role\_name | Name of the role. |
| trusted\_subjects | Exact sub claims the trust policy accepts. Read this in a review instead of decoding the policy JSON. |
| workflow\_snippet | The permissions block and the configure-aws-credentials step a workflow needs to use this role. |
<!-- END_TF_DOCS -->
