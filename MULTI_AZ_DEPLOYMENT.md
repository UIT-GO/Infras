# Multi-AZ Docker Compose Deployment Guide

## Overview
This setup provides true multi-AZ deployment across 2 AWS Availability Zones with cluster/replication for all services.

## Architecture
- **EC2-1 (AZ1)**: Primary database nodes, Kafka broker 1, ELK node 1, Microservices
- **EC2-2 (AZ2)**: Secondary database nodes, Kafka broker 2, ELK node 2, Microservices

## Deployment Steps

### 1. Prepare EC2 Instances
```bash
# On both EC2 instances, install Docker and Docker Compose
sudo yum update -y
sudo yum install -y git
amazon-linux-extras install docker -y
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -a -G docker ec2-user
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

### 2. Get Private IPs
```bash
# On each EC2, get private IP
curl http://169.254.169.254/latest/meta-data/local-ipv4
```

### 3. Update Environment Files
- Copy `.env.az1` to EC2-1 as `.env`
- Copy `.env.az2` to EC2-2 as `.env`
- Replace `PRIVATE_IP_1` and `PRIVATE_IP_2` with actual private IPs

### 4. Deploy Services
```bash
# On both EC2 instances, upload all docker-compose files and run:
docker-compose -f docker-compose-databases.yml \
               -f docker-compose-kafka.yml \
               -f docker-compose-elk.yml \
               -f docker-compose-services.yml up -d
```

### 5. Initialize Clusters
```bash
# On EC2-1, run MongoDB replica set initialization
chmod +x scripts/init-mongodb-cluster.sh
./scripts/init-mongodb-cluster.sh

# Create Kafka topics with replication
chmod +x scripts/create-kafka-topics.sh
./scripts/create-kafka-topics.sh
```

## Service Endpoints
- **ALB**: Load balances between microservices on both AZ
- **MongoDB**: Replica set with automatic failover
- **Kafka**: 2-broker cluster with replication factor 2
- **Redis**: Master-replica setup
- **Elasticsearch**: 2-node cluster
- **PostgreSQL**: Streaming replication (master-standby)

## High Availability Features
- **Database**: Auto failover (MongoDB), replication (PostgreSQL, Redis)
- **Messaging**: Kafka cluster survives single broker failure
- **Search**: Elasticsearch cluster with 2 nodes
- **Applications**: Load balanced across AZ by ALB

## Monitoring
- Kibana: http://ALB_URL:5601
- RedisInsight: http://ALB_URL:8001
- Kafka: Use kafka-topics commands to check cluster health

## Security Considerations
- All inter-node communication uses private IPs
- Services are exposed only through ALB
- Database credentials should be stored in secrets management

## Scaling
- Add more EC2 instances to scale horizontally
- Increase replication factors for better durability
- Use AWS managed services (RDS, MSK, OpenSearch) for production