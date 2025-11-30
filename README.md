# Multi-AZ Microservices Deployment (Terraform + Docker Compose)

This repository contains Terraform and Docker Compose configuration to deploy a multi-AZ microservices environment on AWS. It is designed for resilience across two Availability Zones (AZs) and includes database replication, a Kafka KRaft cluster, and centralized logging.

**Quick summary**
- Infrastructure as code: `main.tf` (VPC, subnets, 2 EC2, ALB, security groups, IAM role/profile)
- Docker Compose split into files:
  - `docker-compose-databases.yml` (Postgres, MongoDB, Redis)
  - `docker-compose-kafka.yml` (Kafka KRaft cluster)
  - `docker-compose-elk.yml` (Elasticsearch, Logstash, Kibana)
  - `docker-compose-services.yml` (auth, driver, trip, notification services)
- Centralized logs: CloudWatch (via `awslogs` driver + CloudWatch Agent for system logs)

**Prerequisites**
- AWS account with permissions to create VPC, EC2, ALB, IAM, CloudWatch
- Terraform installed locally
- SSH key pairs referenced in `main.tf` available
- Docker and Docker Compose on EC2 instances

**File locations**
- `main.tf` — Terraform resources and `user_data` for EC2
- `docker-compose-*.yml` — Compose files for each layer
- `scripts/init-mongodb-cluster.sh` — MongoDB replica set initialization
- `.env.az1`, `.env.az2` — environment files per AZ

## Deployment steps

1. Initialize and apply Terraform (from your workstation / CI):

```powershell
terraform init
terraform plan -out plan.tfplan
terraform apply "plan.tfplan"
```

2. Get outputs (EC2 public IPs, ALB DNS):

```powershell
terraform output
```

3. SSH into each EC2 (AZ1 / AZ2) and prepare env files

```bash
# on your machine
ssh -i EC2-1.pem ec2-user@<EC2_AZ1_PUBLIC_IP>
# copy .env.az1 -> .env and confirm PRIVATE_IP, KAFKA settings, DB URIs

ssh -i EC2-2.pem ec2-user@<EC2_AZ2_PUBLIC_IP>
# copy .env.az2 -> .env and confirm settings
```

4. Start containers in correct order (on both EC2 instances):

```bash
# Databases first
docker-compose -f docker-compose-databases.yml up -d
sleep 20

# Kafka cluster next
docker-compose -f docker-compose-kafka.yml up -d
sleep 60

# ELK (optional)
docker-compose -f docker-compose-elk.yml up -d

# Microservices last
docker-compose -f docker-compose-services.yml up -d
```

5. Initialize MongoDB replica set (once, from primary or configured script):

```bash
chmod +x scripts/init-mongodb-cluster.sh
./scripts/init-mongodb-cluster.sh
# or use mongosh and rs.initiate/add
```

6. Create Kafka topics with replication factor 2 (example script available):

```bash
chmod +x scripts/create-kafka-topics.sh
./scripts/create-kafka-topics.sh
```

## Health checks & verification

- ALB health: `http://<ALB_DNS>/actuator/health`
- Service endpoints:
  - `http://<ALB_DNS>/api/auth`
  - `http://<ALB_DNS>/api/drivers`
  - `http://<ALB_DNS>/api/trips`
- MongoDB replica set status:

```bash
docker exec -it mongodb mongosh --eval "rs.status()"
```

- Kafka topics and consumer groups:

```bash
docker exec -it kafka kafka-topics --bootstrap-server localhost:9092 --list
docker exec -it kafka kafka-consumer-groups --bootstrap-server localhost:9092 --describe --group <group>
```

## Troubleshooting (common problems)

- MongoDB: `MongoTimeoutException` — indicates missing PRIMARY. If using a 2-node replica set, add an arbiter or third data node to ensure majority and automatic failover. Temporary fixes:
  - Restart the downed MongoDB container and wait for sync.
  - Force reconfigure on the remaining node (only if acceptable for your environment).

- Kafka: `Node -1 disconnected` / `NOT_COORDINATOR` — check broker health, advertised listeners, `KAFKA_CONTROLLER_QUORUM_VOTERS` and that `PRIVATE_IP` values in `.env` match instance private IPs. Restarting microservices after Kafka stabilizes usually resolves transient consumer errors.

- CloudWatch permissions: Ensure EC2 IAM role includes `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams`.

## Monitoring & Logs

- Container logs: sent to CloudWatch log groups (configured in `docker-compose-services.yml`) — group names like `/microservices/auth-service`.
- System logs: CloudWatch Agent configured to collect `/var/log/messages`, `/var/log/secure`, and Docker logs into `/ec2/system/*` groups.

## Production recommendations

- Use at least 3 MongoDB nodes (or 2 data + 1 arbiter) for reliable failover.
- Consider managed services (Amazon MSK for Kafka, Amazon RDS/Aurora, or MongoDB Atlas) for production workloads.
- Use Terraform for all infra changes and import any console-made changes into state to avoid drift.
- Use Reserved Instances or Savings Plans for stable cost reduction.

## Next steps / useful commands

- Check target group health in AWS Console (EC2 > Target Groups)
- Check CloudWatch logs:

```bash
aws logs describe-log-groups --log-group-name-prefix "/microservices/"
aws logs tail "/microservices/auth-service" --follow
```
