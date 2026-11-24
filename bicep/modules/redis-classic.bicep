targetScope = 'resourceGroup'

param redisParams object

resource redis 'Microsoft.Cache/redis@2024-11-01' existing = {
  name: redisParams.name
}

output redisName string = redis.name
output redisResourceId string = redis.id
