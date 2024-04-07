: '
Tokens for the Nettskjema API user iaas-project

curl 'https://nettskjema.no/api/v2/submissions/31215102' -i -X GET \
    -H 'Authorization: Bearer TOKEN'

curl 'https://nettskjema.no/api/v2/forms/289417' -i -X GET \
    -H 'Authorization: Bearer TOKEN'
'
# READ_SUBMISSIONS

export NETTSKJEMA_API_SUBMISSIONS_TOKEN=

# READ_FORMS

#export NETTSKJEMA_API_FORMS_TOKEN=
