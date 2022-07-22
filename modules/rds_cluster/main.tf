locals {
  monitoring_role_arn = var.create_monitoring_role ? aws_iam_role.enhanced_monitoring[0].arn : var.monitoring_role_arn

  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.final_snapshot_identifier_prefix}-${var.cluster_identifier}-${try(random_id.snapshot_identifier[0].hex, "")}"

  monitoring_role_name        = var.monitoring_role_use_name_prefix ? null : var.monitoring_role_name
  monitoring_role_name_prefix = var.monitoring_role_use_name_prefix ? "${var.monitoring_role_name}-" : null

  cluster_identifier        = var.use_cluster_identifier_prefix ? null : var.cluster_identifier
  cluster_identifier_prefix = var.use_cluster_identifier_prefix ? "${var.cluster_identifier}-" : null
}

# Ref. https://docs.aws.amazon.com/general/latest/gr/aws-arns-and-namespaces.html#genref-aws-service-namespaces
data "aws_partition" "current" {}

resource "random_id" "snapshot_identifier" {
  count = var.create_cluster && !var.skip_final_snapshot ? 1 : 0

  keepers = {
    id = var.cluster_identifier
  }

  byte_length = 4
}

resource "aws_rds_cluster" "this" {
  count = var.create_cluster ? 1 : 0

  # Notes:
  # iam_roles has been removed from this resource and instead will be used with aws_rds_cluster_role_association below to avoid conflicts per docs

  cluster_identifier            = local.cluster_identifier
  cluster_identifier_prefix     = local.cluster_identifier_prefix
  replication_source_identifier = var.replication_source_identifier
  source_region                 = var.source_region

  # These attributes are required for multi-az deployments
  storage_type              = var.storage_type
  iops                      = var.iops
  allocated_storage         = var.allocated_storage
  db_cluster_instance_class = var.instance_class

  engine                           = var.engine
  engine_mode                      = var.engine_mode
  engine_version                   = var.engine_version
  allow_major_version_upgrade      = var.allow_major_version_upgrade
  kms_key_id                       = var.kms_key_id
  database_name                    = var.db_name
  master_username                  = var.username
  master_password                  = var.password
  final_snapshot_identifier        = local.final_snapshot_identifier
  skip_final_snapshot              = var.skip_final_snapshot
  deletion_protection              = var.deletion_protection
  backup_retention_period          = var.backup_retention_period
  preferred_backup_window          = var.backup_window
  preferred_maintenance_window     = var.maintenance_window
  port                             = var.port
  db_subnet_group_name             = var.db_subnet_group_name
  vpc_security_group_ids           = var.vpc_security_group_ids
  snapshot_identifier              = var.snapshot_identifier
  storage_encrypted                = var.storage_encrypted
  apply_immediately                = var.apply_immediately
  db_cluster_parameter_group_name  = var.db_cluster_parameter_group_name
  db_instance_parameter_group_name = var.allow_major_version_upgrade ? var.db_cluster_db_instance_parameter_group_name : null
  copy_tags_to_snapshot            = var.copy_tags_to_snapshot
  enabled_cloudwatch_logs_exports  = var.enabled_cloudwatch_logs_exports

  timeouts {
    create = lookup(var.cluster_timeouts, "create", null)
    update = lookup(var.cluster_timeouts, "update", null)
    delete = lookup(var.cluster_timeouts, "delete", null)
  }

  dynamic "s3_import" {
    for_each = var.s3_import != null ? [var.s3_import] : []
    content {
      source_engine         = "mysql"
      source_engine_version = s3_import.value.source_engine_version
      bucket_name           = s3_import.value.bucket_name
      bucket_prefix         = lookup(s3_import.value, "bucket_prefix", null)
      ingestion_role        = s3_import.value.ingestion_role
    }
  }

  dynamic "restore_to_point_in_time" {
    for_each = var.restore_to_point_in_time != null ? [var.restore_to_point_in_time] : []

    content {
      source_cluster_identifier  = restore_to_point_in_time.value.source_cluster_identifier
      restore_type               = lookup(restore_to_point_in_time.value, "restore_type", null)
      use_latest_restorable_time = lookup(restore_to_point_in_time.value, "use_latest_restorable_time", null)
      restore_to_time            = lookup(restore_to_point_in_time.value, "restore_to_time", null)
    }
  }

  lifecycle {
    ignore_changes = [
      # See https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster#replication_source_identifier
      # Since this is used either in read-replica clusters or global clusters, this should be acceptable to specify
      replication_source_identifier,
    ]
  }

  tags = merge(var.tags, var.cluster_tags)
}

resource "aws_rds_cluster_role_association" "this" {
  for_each = var.create_cluster ? var.iam_roles : {}

  db_cluster_identifier = try(aws_rds_cluster.this[0].id, "")
  feature_name          = each.value.feature_name
  role_arn              = each.value.role_arn
}

################################################################################
# CloudWatch Log Group
################################################################################

resource "aws_cloudwatch_log_group" "this" {
  for_each = toset([for log in var.enabled_cloudwatch_logs_exports : log if var.create_cluster && var.create_cloudwatch_log_group])

  name              = "/aws/rds/instance/${var.cluster_identifier}/${each.value}"
  retention_in_days = var.cloudwatch_log_group_retention_in_days
  kms_key_id        = var.cloudwatch_log_group_kms_key_id

  tags = var.tags
}

################################################################################
# Enhanced monitoring
################################################################################

data "aws_iam_policy_document" "enhanced_monitoring" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "enhanced_monitoring" {
  count = var.create_monitoring_role ? 1 : 0

  name               = local.monitoring_role_name
  name_prefix        = local.monitoring_role_name_prefix
  assume_role_policy = data.aws_iam_policy_document.enhanced_monitoring.json
  description        = var.monitoring_role_description

  tags = merge(
    {
      "Name" = format("%s", var.monitoring_role_name)
    },
    var.tags,
  )
}

resource "aws_iam_role_policy_attachment" "enhanced_monitoring" {
  count = var.create_monitoring_role ? 1 : 0

  role       = aws_iam_role.enhanced_monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
