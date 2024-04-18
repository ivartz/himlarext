: '
bash iaas-project-cmds.sh FROM_SUBMISSION_ID

Process oldest to newest (FIFO)

FROM_SUBMISSION_ID is included

export NETTSKJEMA_API_SUBMISSIONS_TOKEN=TOKEN
'

fromSubmissionId=$1

if [ -z $NETTSKJEMA_API_SUBMISSIONS_TOKEN ]
then
  echo "NETSKJEMA_API_SUBMISSIONS_TOKEN environmental variable not present, exiting"
  exit
fi

submissionIds=($(bash $(dirname $0)/iaas-project-submission-ids.sh $(($fromSubmissionId-1))))

numSubmissions=${#submissionIds[*]}

# FIFO
for ((i=$(($numSubmissions-1)); i>=0 ; --i))
do
  echo "New submission"
  submissionId=${submissionIds[$i]}
  read -p "#RT for Ref. $submissionId is (Enter to skip) " rt
  #echo "$rt $submissionId"
  if [ ! -z $rt ]
  then
    cmd="bash $(dirname $0)/iaas-project-submission-cmds.sh $rt $submissionId"
    echo $cmd
    eval $cmd
  fi
done
echo "Done"
