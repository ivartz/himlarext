: '
bash iaas-project-submission-cmds.sh RT SUBMISSION_ID

Suggests commands based on submission to
https://nettskjema.no/a/iaas-project (request.nrec.no)

2024-04-06 yyyy-mm-dd

export NETTSKJEMA_API_SUBMISSIONS_TOKEN=TOKEN

Tested on RT SUBMISSION_ID Summary

6165179 31215102 Virtual GPU, with HDD volume quota
6169259 31265206 Shared, with small base quota, custom HDD and SSD volume quota, and other users
6171415 31295900 Shared, with small base quota, HDD and SSD volume quota, and other user
6152187 31136398 Shared, with large base quota, custom shpc flavor, large os disk shpc quota, custom SSD volume quota, and other users
6167493 31243270 Personal, with small base quota
6167041 31235749 -"-
6152026 31134696
6156579 31167241
6132597 30982716
6150965 31122499
6152144 31136133
6147307 31095286
and more

'

set -e

RT=$1
#RT=6152187

SUBMISSION_ID=$2
#SUBMISSION_ID=31136398

data=$(curl -s "https://nettskjema.no/api/v2/submissions/${SUBMISSION_ID}" -i -X GET -H "Authorization: Bearer ${NETTSKJEMA_API_SUBMISSIONS_TOKEN}" | sed -n 20p)

#curl "https://nettskjema.no/api/v2/submissions/${SUBMISSION_ID}" -i -X GET -H "Authorization: Bearer ${NETTSKJEMA_API_SUBMISSIONS_TOKEN}" | sed -n 20p > $SUBMISSION_ID
#data=$(cat $SUBMISSION_ID)

echo

declare -A clues

clues[rt]=$RT
clues[submissionId]=$SUBMISSION_ID
clues[respondentEmail]=$(echo $data | jq '.respondentEmail' | tr -d '"')

numAnswers=$(echo $data | jq '.answers | length')

for ((i=0; i<$numAnswers; ++i))
do
  answer=$(echo $data | jq ".answers[$i]")
  questionId=$(echo $answer | jq '.questionId')
  # Project Type
  if [[ $questionId == 4953372 ]]
  then
    clues[projectType]=$(echo $answer | jq '.answerOptions[0].text' | tr -d '"')
  # Special resources
  elif [[ $questionId == 5520806 ]]
  then
    specialResources=$(echo $answer | jq '.answerOptions')
    numSpecialResources=$(echo $answer | jq '.answerOptions | length')
    for ((j=0; j<$numSpecialResources; ++j))
    do
      specialResource=$(echo $specialResources | jq ".[$j].text" | tr -d '"')
      if [[ $specialResource == 'Shared HPC' ]]
      then
        clues[shpcResource]=$specialResource
      elif [[ $specialResource == 'SSD Storage' ]]
      then
        clues[ssdStorageResource]=$specialResource
      fi
    done
  # Private project base quota
  elif [[ $questionId == 4953376 ]]
	then
    clues[personalProjectBaseQuota]=$(echo $answer | jq '.answerOptions[0].text' | tr -d '"')
  # Shared project base quota
  elif [[ $questionId == 4953375 ]]
  then
    clues[sharedProjectBaseQuota]=$(echo $answer | jq '.answerOptions[0].text' | tr -d '"')
  # Other sHPC flavors
  otherShpcResourcesArray=()
  numOtherShpcResources=0
  elif [[ $questionId == 5520068 ]]
  then
    otherShpcResources=$(echo $answer | jq '.answerOptions')
    numOtherShpcResources=$(echo $answer | jq '.answerOptions | length')
    for ((j=0; j<$numOtherShpcResources; ++j))
    do
      otherShpcResource=$(echo $otherShpcResources | jq ".[$j].text" | tr -d '"')
      otherShpcResourcesArray+=("$otherShpcResource")
    done
  # (if needed) Additional project sHPC quota TODO: users think that base quota is part of this, and we can end up giving more resources than needed. Change to "Extended HPC Quota?"
  # In this script: Total project quota is the largest of base quota and sHPC quota.
  elif [[ $questionId == 5520772 ]]
  then
    clues[projectShpcQuota]=$(echo $answer | jq '.answerOptions[0].text' | tr -d '"')
  # Regular volume quota for shared projects
  elif [[ $questionId == 5520777 ]]
  then
    clues[regularVolumeQuota]=$(echo $answer | jq '.textAnswer' | tr -d '"')
  # SSD volume quota for shared projects
  elif [[ $questionId == 5520812 ]]
  then
    clues[ssdVolumeQuota]=$(echo $answer | jq '.textAnswer' | tr -d '"')
  # Regular volume quota for vgpu projects
  elif [[ $questionId == 5520814 ]]
  then
    clues[regularVolumeQuota]=$(echo $answer | jq '.textAnswer' | tr -d '"')
  # Optional contact
  # TODO: add
  # Project name
  elif [[ $questionId == 4953385 ]]
  then
    clues[projectName]=$(echo $answer | jq '.textAnswer' | tr -d '"')
  # Project description
  elif [[ $questionId == 4953382 ]]
  then
    clues[projectDescription]=$(echo $answer | jq '.textAnswer' | tr -d '"')
  # Expiration date
  elif [[ $questionId == 4953374 ]]
  then
    clues[expirationDate]=$(echo $answer | jq '.textAnswer' | tr -d '"')
  # Educational institution
  elif [[ $questionId == 4953383 ]]
  then
    clues[educationalInstitution]=$(echo $answer | jq '.answerOptions[0].text' | tr -d '"')
  # Project category
  elif [[ $questionId == 4953384 ]]
  then
    clues[projectCategory]=$(echo $answer | jq '.answerOptions[0].text' | tr -d '"')
  # Additional users
  elif [[ $questionId == 4953386 ]]
  then
    clues[additionalUsers]=$(echo $answer | jq '.textAnswer' | tr -d '"')
  # Other
  # TODO: add
  fi
done

# (info overview) print stored keys and values
for key in ${!clues[*]}
do
  value=${clues[$key]}
  #printf "%s\t%s\n" $key "$value"
  echo $key : $value
done
if [ ! -z $numOtherShpcResources ]
then
  for ((j=0; j<$numOtherShpcResources; ++j))
  do
    echo "otherShpcResource $(($j+1)) : ${otherShpcResourcesArray[$j]}"
  done
fi
echo

# Interactive if not Personal project
if [[ ${clues[projectType]} != 'Personal' ]]
then
	# project
	read -e -p "projectName (Enter to continue): " -i "${clues[projectName]}" kanswer
	clues[projectName]=$kanswer

	# description
	# Take the first sentence in projectDescription, as a start
	desc="${clues[projectDescription]}"
	desc="${desc%%.*}"
	read -e -p "projectDescription, first sentence (Enter to continue): " -i "$desc" kanswer
	clues[projectDescription]="$kanswer"

	echo
fi

# Start building cmds

# Build project.py cmd arguments

declare -A pcargs

# createArgument: project.py create or project.py create-private
# Default: create
pcargs[createArgument]=create

# Creating arguments, first for create-private, then for create

# --end
pcargs[end]=$(bash -c 'end="$(echo $0 | cut -d . -f 3)-$(echo $0 | cut -d . -f 2)-$(echo $0 | cut -d . -f 1)"; echo $end' ${clues[expirationDate]})

# -q (choose from 'small', 'medium', 'large', 'vgpu')
declare -A pquotas
# vgpu
if [[ ${clues[projectType]} == 'Virtual GPU' ]]
then
  pcargs[quota]=vgpu
# small, medium in the context of Personal project
elif [[ ${clues[projectType]} == 'Personal' ]]
then
	pcargs[createArgument]=create-private
  if [[ ${clues[personalProjectBaseQuota]} == 'Small: 5 instances, 10 cores and 16 GB RAM' ]]
  then
    pcargs[quota]=small
  elif [[ ${clues[personalProjectBaseQuota]} == 'Medium: 20 instances, 40 cores and 64 GB RAM' ]]
  then
    pcargs[quota]=medium
	fi
# small, medium, large in the context of Shared project
elif [[ ${clues[projectType]} == 'Shared' ]]
then
  # Quota (small, medium, large)
  if [[ ${clues[sharedProjectBaseQuota]} == 'Small: 5 instances, 10 cores and 16 GB RAM' ]]
  then
    pcargs[quota]=small
    pquotas[instances]=5
    pquotas[cores]=10
    pquotas[ram]=$((1024*16))
  elif [[ ${clues[sharedProjectBaseQuota]} == 'Medium: 20 instances, 40 cores and 64 GB RAM' ]]
  then
    pcargs[quota]=medium
    pquotas[instances]=20
    pquotas[cores]=40
    pquotas[ram]=$((1024*64))
  elif [[ ${clues[sharedProjectBaseQuota]} == 'Large: 50 instances, 100 cores and 96 GB RAM' ]]
  then
    pcargs[quota]=large
    pquotas[instances]=50
    pquotas[cores]=100
    pquotas[ram]=$((1024*96))
  fi
fi

# --rt
pcargs[rt]=${clues[rt]}

# institution and region specific options
if [[ ${clues[educationalInstitution]} == 'University of Oslo (UiO)' ]]
then
  # TODO: May need to shorten UiO E-mail to <username>@uio.no. The correct shortened UiO E-mail may be found using bofh on the submitted UiO E-mail in the form.
  # user (create-private)
  pcargs[user]=${clues[respondentEmail]}
  # --region (create)
  pcargs[region]=osl
  # -a (create)
  pcargs[admin]=${clues[respondentEmail]}
  # -o (choose from 'nrec', 'uio', 'uib', 'uit', 'ntnu', 'nmbu', 'vetinst', 'hvl')
  pcargs[org]=uio
  # --contact (create) TODO: If Optional contact was provided, use that instead of respondentEmail.
  pcargs[contact]=${clues[respondentEmail]}
elif [[ ${clues[educationalInstitution]} == 'University of Bergen (UiB)' ]]
then
  # user (create-private)
  pcargs[user]=${clues[respondentEmail]}
  # --region (create)
  pcargs[region]=bgo
  # -a (create)
  pcargs[admin]=${clues[respondentEmail]}
  # -o (choose from 'nrec', 'uio', 'uib', 'uit', 'ntnu', 'nmbu', 'vetinst', 'hvl')
  pcargs[org]=uib
  # --contact (create)
  pcargs[contact]=${clues[respondentEmail]}
else
  # user (create-private)
  pcargs[user]=${clues[respondentEmail]}
  # --region (create)
  pcargs[region]=None
   # -a (create)
  pcargs[admin]=${clues[respondentEmail]}
  # -o (choose from 'nrec', 'uio', 'uib', 'uit', 'ntnu', 'nmbu', 'vetinst', 'hvl')
  pcargs[org]=None
  # --contact (create)
  pcargs[contact]=${clues[respondentEmail]}
fi

# -t (choose from 'admin', 'demo', 'personal', 'research', 'education', 'course', 'test', 'hpc', 'vgpu') TODO: add the remaining options
if [[ ${clues[projectType]} == 'Virtual GPU' ]]
then
  pcargs[pctype]=vgpu
elif [[ ${clues[projectCategory]} == 'Admin' ]]
then
  pcargs[pctype]=admin
elif [[ ${clues[projectCategory]} == 'Research' ]]
then
  pcargs[pctype]=research
elif [[ ${clues[projectCategory]} == 'Education' ]]
then
  pcargs[pctype]=education
fi

# --desc
pcargs[desc]="'${clues[projectDescription]}'"

# project (create)
pcargs[project]=${clues[projectName]}

# Parse full project.py cmd
if [[ ${pcargs[createArgument]} == create-private ]]
then
  cmd="./project.py create-private --end ${pcargs[end]} -q ${pcargs[quota]} --rt ${pcargs[rt]} -m ${pcargs[admin]}"
elif [[ ${pcargs[createArgument]} == create ]]
then
  #cmd="./project.py create --region ${pcargs[region]} --end ${pcargs[end]} -a ${pcargs[admin]} -t ${pcargs[pctype]} --desc ${pcargs[desc]} -o ${pcargs[org]} --contact ${pcargs[contact]} -q ${pcargs[quota]} --rt ${pcargs[rt]} -m ${pcargs[project]}"
  cmd="./project.py create --end ${pcargs[end]} -a ${pcargs[admin]} -t ${pcargs[pctype]} --desc ${pcargs[desc]} -o ${pcargs[org]} --contact ${pcargs[contact]} -q ${pcargs[quota]} --rt ${pcargs[rt]} -m ${pcargs[project]}"
fi

echo $cmd

# Build project.py grant cmd -u arguments
if [[ ${pcargs[createArgument]} != create-private ]]
then
  if [ ! -z ${clues[additionalUsers]} ]
  then
    pguserargs=$(bash -c 'users=(${0//\\r\\n/ }); for u in ${users[*]}; do echo -n "-u $u "; done' ${clues[additionalUsers]})
    pguserargs="-u ${pcargs[admin]} $pguserargs"

    # Parse full project.py grant cmd
    cmd="./project.py grant $pguserargs --rt ${pcargs[rt]} -m ${pcargs[project]}"
    echo $cmd
  else
    cmd="./project.py grant -u ${pcargs[admin]} --rt ${pcargs[rt]} -m ${pcargs[project]}"
    echo $cmd
  fi
fi

# Project access grants (choose from 'vgpu', 'shpc', 'shpc_ram', 'shpc_disk1', 'shpc_disk2', 'shpc_disk3', 'shpc_disk4', 'ssd', 'net_uib', 'net_educloud') TODO: add logic for: 'net_uib', 'net_educloud
if [[ ${clues[projectType]} == 'Virtual GPU' ]]
then
  cmd="./project.py access --region ${pcargs[region]} --grant vgpu ${pcargs[project]}"
  echo $cmd
fi
if [ ! -z "${clues[shpcResource]}" ]
then
  # The balanced (shpc.m1a) and CPU-bound (shpc.c1a) flavor sets are included by default with shpc
  cmd="./project.py access --region ${pcargs[region]} --grant shpc ${pcargs[project]}"
  echo $cmd
fi
if [ ! -z "${clues[ssdStorageResource]}" ]
then
  cmd="./project.py access --region ${pcargs[region]} --grant ssd ${pcargs[project]}"
  echo $cmd
fi

# Access to other possible sHPC flavors specified in the form: shpc.r1a, shpc.m1ad1, shpc.m1ad2, shpc.m1ad3, shpc.m1ad4
# .. and required resources: 'shpc_ram', 'shpc_disk1', 'shpc_disk2', 'shpc_disk3', 'shpc_disk4'
if [ ${#otherShpcResourcesArray} -gt 0 ]
then
  for ((j=0; j<$numOtherShpcResources; ++j))
  do
    otherShpcResource=${otherShpcResourcesArray[$j]}
    otherShpcResource=${otherShpcResource##*\(}
    otherShpcResource=${otherShpcResource%%\)*}
    if [[ $otherShpcResource == 'shpc.r1a' ]]
    then
      cmd="./project.py access --region ${pcargs[region]} --grant shpc_ram ${pcargs[project]}"
      echo $cmd
    elif [[ $otherShpcResource == 'shpc.m1ad1' ]]
    then
      cmd="./project.py access --region ${pcargs[region]} --grant shpc_disk1 ${pcargs[project]}"
      echo $cmd
    elif [[ $otherShpcResource == 'shpc.m1ad2' ]]
    then
      cmd="./project.py access --region ${pcargs[region]} --grant shpc_disk2 ${pcargs[project]}"
      echo $cmd
    elif [[ $otherShpcResource == 'shpc.m1ad3' ]]
    then
      cmd="./project.py access --region ${pcargs[region]} --grant shpc_disk3 ${pcargs[project]}"
      echo $cmd
    elif [[ $otherShpcResource == 'shpc.m1ad4' ]]
    then
      cmd="./project.py access --region ${pcargs[region]} --grant shpc_disk4 ${pcargs[project]}"
      echo $cmd
    fi
    cmd="./flavor.py grant --region ${pcargs[region]} $otherShpcResource ${pcargs[project]}"
    echo $cmd
  done
fi

# Set custom HDD and SSD volume quotas
if [ ! -z ${clues[regularVolumeQuota]} ]
then
  # Parse full openstack HDD quota set cmd
  cmd="openstack quota set --gigabytes ${clues[regularVolumeQuota]} ${pcargs[project]}"
  echo $cmd
fi
if [ ! -z ${clues[ssdVolumeQuota]} ]
  then
  # Parse full openstack SSD quota set cmd
  cmd="openstack quota set --volume-type mass-storage-ssd --gigabytes ${clues[ssdVolumeQuota]} ${pcargs[project]}"
  echo $cmd
fi

# Set increased cores and ram if specified sHPC quota are larger than base quota
if [ ! -z "${clues[projectShpcQuota]}" ]
then
  if [[ ${clues[projectShpcQuota]} == 'Small: 8 CPUs, 32 GB memory' ]]
  then
    shpcCores=8
    shpcRamGB=32
  elif [[ ${clues[projectShpcQuota]} == 'Medium: 16 CPUs, 64 GB memory' ]]
  then
    shpcCores=16
    shpcRamGB=64
  elif [[ ${clues[projectShpcQuota]} == 'Large: 32 CPUs, 128 GB memory' ]]
  then
    shpcCores=32
    shpcRamGB=128
  elif [[ ${clues[projectShpcQuota]} == 'Extra Large: 64 CPUs, 256 GB memory' ]]
  then
    shpcCores=64
    shpcRamGB=256
  elif [[ ${clues[projectShpcQuota]} == 'Big Memory: 64 CPUs, 384 GB memory' ]]
  then
    shpcCores=64
    shpcRamGB=384
  elif [[ ${clues[projectShpcQuota]} == 'Other (specify below)' ]]
  then
    # TODO: Instead read from the Other field (not parsed)
    read -p "shpcCores: " shpcCores
    read -p "shpcRamGB: " shpcRamGB
  fi
  # Increase cores and RAM if necessary
  # Cores
  if [ $shpcCores -gt ${pquotas[cores]} ]
  then
    pquotas[cores]=$shpcCores
    cmd="openstack quota set --cores ${pquotas[cores]}"
    echo $cmd
  fi
  # RAM
  ram=$((1024*$shpcRamGB))
  if [ $ram -gt ${pquotas[ram]} ]
  then
    pquotas[ram]=$ram
    cmd="openstack quota set --ram ${pquotas[ram]}"
    echo $cmd
  fi
fi
echo
