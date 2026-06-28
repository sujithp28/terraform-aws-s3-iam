resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name
  tags   = merge(var.tags, { Name = var.bucket_name })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration { status = var.enable_versioning ? "Enabled" : "Suspended" }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    id     = "transition-and-expiry"
    status = "Enabled"
    filter { prefix = "" }
    transition { days = var.lifecycle_glacier_days; storage_class = "GLACIER" }
    expiration { days = var.lifecycle_expiry_days }
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

resource "aws_s3_bucket_policy" "enforce_tls" {
  bucket = aws_s3_bucket.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Sid = "DenyNonTLS"; Effect = "Deny"; Principal = "*"; Action = "s3:*"; Resource = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]; Condition = { Bool = { "aws:SecureTransport" = "false" } } }]
  })
  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_iam_role" "replication" {
  count = var.enable_replication ? 1 : 0
  name  = "${var.bucket_name}-replication-role"
  assume_role_policy = jsonencode({ Version = "2012-10-17"; Statement = [{ Action = "sts:AssumeRole"; Effect = "Allow"; Principal = { Service = "s3.amazonaws.com" } }] })
  tags  = var.tags
}

resource "aws_iam_role_policy" "replication" {
  count = var.enable_replication ? 1 : 0
  role  = aws_iam_role.replication[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow"; Action = ["s3:GetReplicationConfiguration","s3:ListBucket"]; Resource = aws_s3_bucket.this.arn },
      { Effect = "Allow"; Action = ["s3:GetObjectVersionForReplication","s3:GetObjectVersionAcl","s3:GetObjectVersionTagging"]; Resource = "${aws_s3_bucket.this.arn}/*" },
      { Effect = "Allow"; Action = ["s3:ReplicateObject","s3:ReplicateDelete","s3:ReplicateTags"]; Resource = "${var.replication_destination_bucket_arn}/*" }
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "this" {
  count  = var.enable_replication ? 1 : 0
  bucket = aws_s3_bucket.this.id
  role   = aws_iam_role.replication[0].arn
  rule {
    id = "full-replication"; status = "Enabled"
    filter { prefix = "" }
    destination { bucket = var.replication_destination_bucket_arn; storage_class = "STANDARD_IA" }
  }
  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_iam_role" "roles" {
  for_each = var.iam_roles
  name        = each.key
  description = each.value.description
  assume_role_policy = jsonencode({ Version = "2012-10-17"; Statement = [{ Action = "sts:AssumeRole"; Effect = "Allow"; Principal = { Service = each.value.trusted_services } }] })
  tags = merge(var.tags, { Name = each.key })
}

resource "aws_iam_role_policy_attachment" "roles" {
  for_each = {
    for pair in flatten([for role_name, role in var.iam_roles : [for policy_arn in role.managed_policy_arns : { key = "${role_name}__${policy_arn}"; role_name = role_name; policy_arn = policy_arn }]]) : pair.key => pair
  }
  role       = aws_iam_role.roles[each.value.role_name].name
  policy_arn = each.value.policy_arn
}
