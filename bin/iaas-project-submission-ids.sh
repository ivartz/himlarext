: '
bash iaas-project-submission-ids.sh FROM_SUBMISSION_ID

FROM_SUBMISSION_ID not included

export NETTSKJEMA_API_SUBMISSIONS_TOKEN=TOKEN
'

FROM_SUBMISSION_ID=$1

submissions_json=$(curl -s "https://nettskjema.no/api/v2/forms/289417/submissions?fields=submissionId&fromSubmissionId=${FROM_SUBMISSION_ID}" -i -X GET -H "Authorization: Bearer ${NETTSKJEMA_API_SUBMISSIONS_TOKEN}" | sed -n 20p)

numSubmissions=$(echo $submissions_json | jq 'length')

for ((i=0; i<$numSubmissions; ++i))
do
  echo $submissions_json | jq ".[$i].submissionId"
done
