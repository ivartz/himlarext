# Example for test01:

#OS_AUTH_URL='https://api.test.iaas.uib.no:5000/v3'
#OS_PASSWORD=<from openrc>

curl -i -H "Content-Type: application/json" -d "
  { \"auth\": {
      \"identity\": {
        \"methods\": [\"password\"],
        \"password\": {
          \"user\": {
            \"name\": \"admin\",
            \"domain\": { \"id\": \"default\" },
            \"password\": \"${OS_PASSWORD}\"
          }
        }
      },
      \"scope\": {
        \"project\": {
          \"name\": \"admin\",
          \"domain\": { \"id\": \"default\" }
        }
      }
    }
  }" ${OS_AUTH_URL}/auth/tokens; echo
