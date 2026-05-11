# automating-backups-with-s3-lifecycle

This recipe demonstrates how to implement automated, scheduled backups using Amazon S3, EventBridge, and Lambda. S3's durability, versioning capabilities, and lifecycle policies make it an ideal backup target. EventBridge provides precise scheduling control, while Lambda handles the automation logic.

The solution creates a primary S3 bucket for your working data and a separate backup bucket with versioning enabled. An EventBridge rule triggers a Lambda function on a customizable schedule, which then copies objects from the primary bucket to the backup bucket. Lifecycle policies automatically transition older backups to cost-effective storage classes and can eventually expire them based on your retention requirements.


