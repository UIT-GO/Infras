#!/bin/bash

# MongoDB Replica Set Initialization Script
# Run this script on EC2-1 after both MongoDB instances are running

echo "Initializing MongoDB Replica Set..."

# Wait for MongoDB to be ready
sleep 30

# Initialize replica set
docker exec -it mongodb mongosh --eval "
rs.initiate({
  _id: 'rs0',
  members: [
    { _id: 0, host: '10.10.1.156:27017' },
    { _id: 1, host: '10.10.2.162:27017' }
  ]
})
"

echo "MongoDB Replica Set initialized!"

# Check replica set status
docker exec -it mongodb mongosh --eval "rs.status()"