#!/usr/bin/env bash
###################################
# Migrate database schema #
# [USAGE]                         #
# /bin/bash migrate_schema.sh #
###################################

###########################
#   환경 변수 파일 읽고 설정   #
###########################
# 초기 변수 설정
# 생성될 스키마 파일
schema_file="develop_db_schema.sql"

# Test DB가 생성될 docker container 이름
container_name="local_test_db"

# 실행할 Postgres image version
postgres_image="postgres:9.6-alpine"

# 스키마 생성후 실행할 쿼리파일
insert_sql_path="../sql/insert_query.sql"
insert_sql="insert_query.sql"

# 접속정보 파일 읽어서 변수에 담기
echo " [INFO] Import DB config file"
. ./config


###################################
# Source db 기준으로 스키마 파일 생성  #
###################################
function backup_schema {
    # 파라미터
    db_name=$1

    # 스키마 파일을 생성
    command="docker exec -e PGPASSWORD=${source_db_password} ${container_name} pg_dump --host=${source_db_host} --username=${source_db_user}  --port=${source_db_port} --schema-only --dbname=${db_name} > ${schema_file}"
    if ! eval $command ; then
      echo " [ERROR] Failed to create schema file."
      rm ${schema_file}
      exit 1
    fi

    # 스키마 파일의 Owner를 Source에서 Target으로 변경.
    if [[ "${target_db_host}"=="localhost" ]] || [[ "${target_db_host}"=="127.0.0.1" ]]
    then
      # Public 스키마는 직접 생성
      echo "CREATE SCHEMA public; ALTER SCHEMA public OWNER TO ${target_db_user} ;" | cat - ${schema_file} >> schema_file_tmp && mv schema_file_tmp ${schema_file}

      # Develop DB에서 가져온 스키마에서 Owner를 Test 용으로 변경
      perl -pi -w -e "s/${source_db_user}/${target_db_user}/g;" ${schema_file}
    fi

    # 생성한 스키마 파일을 docker 컨테이너 안으로 복사
    docker cp ${schema_file} ${container_name}:/
}

#########################
# Target db에 스키마 복원  #
#########################
function restore_schema {
    # 파라미터
    db_name=$1

    # 스키마를 Target DB에 생성
    docker exec -e PGPASSWORD="${target_db_password}" ${container_name} psql --host=${target_db_host} --username=${target_db_user} --port=${target_db_port} --dbname=${db_name} --file=${schema_file} >&/dev/null

    # DB에 필요한 기초정보를 위한 작업
    docker cp ${insert_sql_path} ${container_name}:/
    docker exec -e PGPASSWORD="${target_db_password}" ${container_name} psql --host=${target_db_host} --username=${target_db_user} --port=${target_db_port} --dbname=${db_name} --file=${insert_sql} >&/dev/null
}

#######################################
# 스키마 싱크에 사용한 임시파일 삭제         #
#######################################
function clear_temp_files {
  docker exec ${container_name} rm ${schema_file}
  docker exec ${container_name} rm ${insert_sql}
  rm ${schema_file}
}

###########################################
#                                         #
#                Main Loop                #
#                                         #
###########################################

# DB 정보 설정
source_dblist=($source_db_list)
target_dblist=($target_db_list)
db_count=${#source_dblist[@]}

# Database Docker 컨테이너 실행 확인
if [[ $(docker inspect -f '{{.State.Running}}' $container_name 2>/dev/null) = "true" ]] ; then
  echo " [INFO] Docker Container is already running"
else
  echo " [INFO] Docker Container is starting"
fi

# 기존 컨테이너 제거
echo " [INFO] Stop and remove old Postgresql container"
docker stop ${container_name} 2>/dev/null
docker rm ${container_name} 2>/dev/null

# 새로운 컨테이너 생성
echo " [INFO] Generate new Postgresql container"
docker run -d --name ${container_name} \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e POSTGRES_USER=${target_db_user} \
  -e POSTGRES_PASSWORD=${target_db_password} \
  -p 127.0.0.1:${target_db_port}:${target_db_port} \
  ${postgres_image}

# Docker 컨테이너가 실행되는 시간을 위하여 잠시대기
sleep 7 

for ((i=0;i<db_count;i++))
do
    source_db=${source_dblist[i]}
    target_db=${target_dblist[i]}

    # 초기 Database 생성
    echo " [INFO] Creating test database..."
    docker exec ${container_name} psql -U ${target_db_user} -c "create database ${target_db};"

    # Develop DB에서 스키마 생성
    echo " [INFO] Creating ${db_name} schema..."
    backup_schema ${source_db}

    # 스키마 파일로 test db에 복원
    echo " [INFO] Restoring schema -> $db_name"
    restore_schema ${target_db}

    # 임시파일들 모두 삭제
    echo " [INFO] Clear temp files"
    clear_temp_files
done

echo " [INFO] Finish"

