data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name                             = "${var.project}-${var.environment}"
  cluster_name                     = "${local.name}-eks"
  ecr_image_url                    = "${aws_ecr_repository.chatwoot.repository_url}:${var.image_tag}"
  github_actions_oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
  github_actions_repositories      = distinct(concat([var.github_actions_repository], var.github_actions_extra_repositories))
  github_actions_subjects = flatten([
    for repository in local.github_actions_repositories : [
      "repo:${repository}:ref:refs/heads/${var.github_branch}",
      "repo:${repository}:environment:production"
    ]
  ])
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Service     = "chatwoot"
  }
}

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "random_password" "secret_key_base" {
  length  = 96
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}

resource "aws_vpc" "this" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = local.name
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = local.name
  }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(aws_vpc.this.cidr_block, 4, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name                                          = "${local.name}-public-${count.index + 1}"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private_db" {
  count = 2

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(aws_vpc.this.cidr_block, 8, 128 + count.index)

  tags = {
    Name = "${local.name}-private-db-${count.index + 1}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${local.name}-public"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "eks_cluster" {
  name        = "${local.name}-eks-cluster"
  description = "EKS control plane security group"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "PostgreSQL access from EKS nodes"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "redis" {
  name        = "${local.name}-redis"
  description = "Redis access from EKS nodes"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "eks_cluster" {
  name = "${local.name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.36"

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = false
    endpoint_public_access  = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]

  tags = {
    Name = local.cluster_name
  }
}

resource "aws_iam_role" "eks_node" {
  name = "${local.name}-eks-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_node_worker" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name}-default"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.public[*].id

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  disk_size      = 30
  instance_types = ["t3.medium"]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_worker,
    aws_iam_role_policy_attachment.eks_node_cni,
    aws_iam_role_policy_attachment.eks_node_ecr
  ]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"
}

resource "aws_db_subnet_group" "chatwoot" {
  name       = local.name
  subnet_ids = aws_subnet.private_db[*].id
}

resource "aws_db_instance" "chatwoot" {
  identifier              = local.name
  engine                  = "postgres"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  max_allocated_storage   = 100
  storage_type            = "gp3"
  db_name                 = "chatwoot_production"
  username                = "chatwoot"
  password                = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.chatwoot.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 7
}

resource "aws_elasticache_subnet_group" "chatwoot" {
  name       = local.name
  subnet_ids = aws_subnet.private_db[*].id
}

resource "aws_elasticache_replication_group" "chatwoot" {
  replication_group_id = "${local.name}-redis"
  description          = "Chatwoot Redis"
  engine               = "redis"
  node_type            = "cache.t4g.micro"
  num_cache_clusters   = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.1"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.chatwoot.name
  security_group_ids   = [aws_security_group.redis.id]

  transit_encryption_enabled = true
  auth_token                 = random_password.redis.result
}

resource "aws_s3_bucket" "uploads" {
  bucket = "${local.name}-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_ecr_repository" "chatwoot" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "chatwoot" {
  repository = aws_ecr_repository.chatwoot.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_role" "github_actions_deploy" {
  name = "${local.name}-github-actions-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.github_actions_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = local.github_actions_subjects
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "${local.name}-github-actions-deploy"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = aws_ecr_repository.chatwoot.arn
      },
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster"
        ]
        Resource = aws_eks_cluster.this.arn
      }
    ]
  })
}

resource "aws_eks_access_entry" "github_actions_deploy" {
  cluster_name      = aws_eks_cluster.this.name
  kubernetes_groups = ["chatwoot-deployers"]
  principal_arn     = aws_iam_role.github_actions_deploy.arn
  type              = "STANDARD"
}

resource "kubernetes_role" "github_actions_deploy" {
  metadata {
    name      = "github-actions-deploy"
    namespace = kubernetes_namespace.chatwoot.metadata[0].name
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "patch", "update"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "github_actions_deploy" {
  metadata {
    name      = "github-actions-deploy"
    namespace = kubernetes_namespace.chatwoot.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "chatwoot-deployers"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.github_actions_deploy.metadata[0].name
  }
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "alb_controller" {
  name = "${local.name}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "alb_controller" {
  name = "${local.name}-alb-controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "iam:CreateServiceLinkedRole",
        "ec2:DescribeAccountAttributes",
        "ec2:DescribeAddresses",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeVpcs",
        "ec2:DescribeVpcPeeringConnections",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeInstances",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeTags",
        "ec2:GetCoipPoolUsage",
        "ec2:DescribeCoipPools",
        "ec2:GetSecurityGroupsForVpc",
        "ec2:CreateSecurityGroup",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:DeleteSecurityGroup",
        "elasticloadbalancing:*",
        "acm:DescribeCertificate",
        "acm:ListCertificates",
        "acm:GetCertificate",
        "cognito-idp:DescribeUserPoolClient",
        "waf-regional:GetWebACL",
        "waf-regional:GetWebACLForResource",
        "waf-regional:AssociateWebACL",
        "waf-regional:DisassociateWebACL",
        "wafv2:GetWebACL",
        "wafv2:GetWebACLForResource",
        "wafv2:AssociateWebACL",
        "wafv2:DisassociateWebACL",
        "shield:GetSubscriptionState",
        "shield:DescribeProtection",
        "shield:CreateProtection",
        "shield:DeleteProtection"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  timeout    = 900

  set {
    name  = "clusterName"
    value = aws_eks_cluster.this.name
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = aws_vpc.this.id
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller.arn
  }

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.alb_controller
  ]
}

resource "aws_iam_role" "chatwoot" {
  name = "${local.name}-app"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:chatwoot:chatwoot"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "chatwoot_s3" {
  name = "${local.name}-s3"
  role = aws_iam_role.chatwoot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.uploads.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.uploads.arn}/*"
      }
    ]
  })
}

resource "kubernetes_namespace" "chatwoot" {
  metadata {
    name = "chatwoot"
  }

  depends_on = [aws_eks_node_group.this]
}

resource "helm_release" "chatwoot" {
  name       = "chatwoot"
  repository = "https://chatwoot.github.io/charts"
  chart      = "chatwoot"
  namespace  = kubernetes_namespace.chatwoot.metadata[0].name
  wait       = false
  timeout    = 900

  values = [
    yamlencode({
      image = {
        repository = aws_ecr_repository.chatwoot.repository_url
        tag        = var.image_tag
        pullPolicy = "Always"
      }

      postgresql = {
        enabled        = false
        postgresqlHost = aws_db_instance.chatwoot.address
        postgresqlPort = 5432
        auth = {
          username         = aws_db_instance.chatwoot.username
          postgresPassword = random_password.db.result
          database         = aws_db_instance.chatwoot.db_name
        }
      }

      redis = {
        enabled  = false
        host     = aws_elasticache_replication_group.chatwoot.primary_endpoint_address
        port     = 6379
        password = random_password.redis.result
      }

      serviceAccount = {
        create = true
        name   = "chatwoot"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.chatwoot.arn
        }
      }

      web = {
        replicaCount = 1
        hpa = {
          enabled = false
        }
        resources = {
          requests = {
            cpu    = "250m"
            memory = "512Mi"
          }
          limits = {
            cpu    = "750m"
            memory = "1024Mi"
          }
        }
      }

      worker = {
        replicaCount = 1
        hpa = {
          enabled = false
        }
        resources = {
          requests = {
            cpu    = "250m"
            memory = "512Mi"
          }
          limits = {
            cpu    = "750m"
            memory = "1024Mi"
          }
        }
      }

      hooks = {
        migrate = {
          resources = {
            requests = {
              memory = "512Mi"
            }
            limits = {
              memory = "1024Mi"
            }
          }
        }
      }

      services = {
        name         = "chatwoot"
        type         = "ClusterIP"
        internalPort = 3000
        targetPort   = 3000
      }

      ingress = {
        enabled          = true
        ingressClassName = "alb"
        annotations = {
          "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
          "alb.ingress.kubernetes.io/target-type"      = "ip"
          "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTP\": 80}, {\"HTTPS\": 443}]"
          "alb.ingress.kubernetes.io/ssl-redirect"     = "443"
          "alb.ingress.kubernetes.io/certificate-arn"  = var.certificate_arn
          "alb.ingress.kubernetes.io/healthcheck-path" = "/"
        }
        hosts = [{
          host = var.domain_name
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "chatwoot"
                port = {
                  number = 3000
                }
              }
            }
          }]
        }]
      }

      env = {
        ACTIVE_STORAGE_SERVICE               = "amazon"
        AUTONOMIA_AGENTS_ENABLED             = tostring(var.autonomia_agents_enabled)
        AUTONOMIA_AGENTS_GLOBAL              = tostring(var.autonomia_agents_global)
        AUTONOMIA_AUTH_CLIENT_ID             = var.autonomia_auth_client_id
        AUTONOMIA_AUTH_CONTEXT_ENDPOINT      = var.autonomia_auth_context_endpoint
        AUTONOMIA_AUTH_ISSUER                = var.autonomia_auth_issuer
        AUTONOMIA_AUTH_REDIRECT_URI          = "https://${var.domain_name}/auth/autonomia/callback"
        AUTONOMIA_AUTH_TOKEN_ENDPOINT        = var.autonomia_auth_token_endpoint
        AUTONOMIA_SSO_AUTO_REDIRECT          = tostring(var.autonomia_sso_auto_redirect)
        AUTONOMIA_SSO_ENABLED                = tostring(var.autonomia_sso_enabled)
        AUTONOMIA_SSO_URL                    = "/auth/autonomia"
        AWS_REGION                           = var.aws_region
        CAMPAIGN_IMPORT_ENABLED              = tostring(var.campaign_import_enabled)
        CHATWOOT_BASE_URL                    = "https://${var.domain_name}"
        CRM_AI_ENABLED                       = tostring(var.crm_ai_enabled)
        CRM_AI_MEDIA_ENABLED                 = tostring(var.crm_ai_media_enabled)
        CRM_KANBAN_ENABLED                   = tostring(var.crm_kanban_enabled)
        CW_EDITION                           = var.cw_edition
        EMAIL_CAMPAIGN_AWS_ACCESS_KEY_ID     = var.email_campaign_aws_access_key_id
        EMAIL_CAMPAIGN_AWS_REGION            = var.email_campaign_aws_region
        EMAIL_CAMPAIGN_AWS_SECRET_ACCESS_KEY = var.email_campaign_aws_secret_access_key
        EMAIL_CAMPAIGN_ENABLED               = tostring(var.email_campaign_enabled)
        ENABLE_ACCOUNT_SIGNUP                = tostring(var.enable_account_signup)
        FORCE_SSL                            = "false"
        FRONTEND_URL                         = "https://${var.domain_name}"
        INSTALLATION_ENV                     = "aws-eks"
        LOG_LEVEL                            = "info"
        MAILER_SENDER_EMAIL                  = var.mailer_sender_email
        RAILS_ENV                            = "production"
        RAILS_LOG_TO_STDOUT                  = "true"
        REDIS_TLS                            = "true"
        S3_BUCKET_NAME                       = aws_s3_bucket.uploads.bucket
        SECRET_KEY_BASE                      = random_password.secret_key_base.result
        SMTP_ADDRESS                         = var.smtp_address
        SMTP_AUTHENTICATION                  = "plain"
        SMTP_ENABLE_STARTTLS_AUTO            = "true"
        SMTP_OPENSSL_VERIFY_MODE             = "none"
        SMTP_PASSWORD                        = var.smtp_password
        SMTP_PORT                            = "587"
        SMTP_USERNAME                        = var.smtp_username
        WAHA_API_KEY                         = var.waha_api_key
        WAHA_API_URL                         = var.waha_api_url
        WAHA_CHATWOOT_ACCOUNT_TOKEN          = var.waha_chatwoot_account_token
        WAHA_PUBLIC_URL                      = var.waha_public_url
        WHATSAPP_API_CAMPAIGNS_ENABLED       = tostring(var.whatsapp_api_campaigns_enabled)
      }
    })
  ]

  depends_on = [
    helm_release.aws_load_balancer_controller,
    aws_iam_role_policy.chatwoot_s3
  ]
}
