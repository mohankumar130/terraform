provider "aws" {
  region = "ap-south-1"
}

variable "retention_minutes" {
  description = "Number of minutes to retain snapshots"
  type        = number
  default     = 10
}

# Fetching the instance IDs using an external data source
data "aws_instances" "test" {
  filter {
    name   = "tag:env"
    values = ["uat"]
  }

  instance_state_names = ["running", "stopped"]
}

# Fetching EBS volumes attached to the instances
data "aws_ebs_volumes" "test_volumes" {
  filter {
    name   = "attachment.instance-id"
    values = data.aws_instances.test.ids
  }
}

# Output the instance IDs
output "instance_ids" {
  value = data.aws_instances.test.ids
}

# Output the EBS volume details
output "ebs_volumes" {
  value = data.aws_ebs_volumes.test_volumes.ids
}

resource "aws_ebs_snapshot" "test_snapshot" {
  for_each = toset(data.aws_ebs_volumes.test_volumes.ids)

  volume_id = each.value
  tags = {
    Name        = "Automated_snapshot_${each.value}"
    description = "Automated_snapshot_${each.value}"
    CreatedBy   = "Terraform"
    Instance    = data.aws_instances.test.ids[0]  # First instance ID
    Timestamp   = timeadd(timestamp(), "5h30m")
  }
}

# Output the snapshot IDs
# output "snapshots_details" {
#   value = [for snapshot in aws_ebs_snapshot.test_snapshot : snapshot.id]
# }

# Fetching the snapshots to validate the creation
data "aws_ebs_snapshot" "list_snap" {
  for_each = toset(data.aws_ebs_volumes.test_volumes.ids)

  filter {
    name   = "volume-id"
    values = [each.key]
  }
  filter {
    name   = "tag:CreatedBy"
    values = ["Terraform"]
  }
  depends_on = [aws_ebs_snapshot.test_snapshot]
}

# Output the snapshots after creation
output "after_snapshot" {
  value = [for snapshot in data.aws_ebs_snapshot.list_snap : snapshot.id]
}

# Identify snapshots older than retention period and exclude manual snapshots
locals {
  expired_snapshots = [
    for snapshot in data.aws_ebs_snapshot.list_snap :
    snapshot.id if (
      snapshot.tags["CreatedBy"] == "Terraform" && # Only snapshots created by Terraform
      timeadd(snapshot.start_time, "${var.retention_minutes}m") < timestamp()
    )
  ]
}

# Output expired snapshots for verification
output "expired_snapshots" {
  value = local.expired_snapshots
}

# Delete expired snapshots
resource "null_resource" "delete_expired_snapshots" {
  count = length(tolist(local.expired_snapshots))

  provisioner "local-exec" {
    command = "aws ec2 delete-snapshot --snapshot-id ${tolist(local.expired_snapshots)[count.index]}"
  }
}

