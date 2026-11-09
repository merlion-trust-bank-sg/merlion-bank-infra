output "databases" {
  description = "Per database: address, port, database name, admin user and the Secrets Manager secret holding its password"
  value = { for k, db in aws_db_instance.this : k => {
    address           = db.address
    port              = db.port
    db_name           = db.db_name
    username          = db.username
    master_secret_arn = db.master_user_secret[0].secret_arn
  } }
}

output "security_group_id" {
  value = aws_security_group.db.id
}
