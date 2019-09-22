#!/bin/bash

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
NORMAL=$(tput sgr0)
col=$(tput cols)

BASEDIR=$(dirname $0)
NUM_OF_KILO_CALLS=200
NUM_OF_USERS=50
NUM_OF_CALLS=$((NUM_OF_KILO_CALLS*1000))
URL=http://127.0.0.1:8080/
JBOSS_EAP_ZIP_FILE=jboss-eap-7.3.0.Beta.zip
JBOSS_WS_ZIP_FILE=jws-application-server-5.0.0.zip


function action {
    IFS='%'
    local __actionstr=$1
    local __action=$2
    local __actionstrlenght=${#__actionstr}

    printf ${__actionstr}

    let __spaces=${col}-${__actionstrlenght}

    eval ${__action}

    if [ $? -eq 0 ]; then
        printf '%s%*s%s' "$GREEN" $__spaces "[OK]" "$NORMAL"
    else
        printf '%s%*s%s' "$RED" $__spaces "[FAIL]" "$NORMAL"
    fi
    printf "\n"

}

function mvn_build_project {
    local __app_name=${1}
    local __build_param=${2}    
    local __project_dir="$BASEDIR/projects/${__app_name}"
    echo "    mvn -q -f ${__project_dir}/pom.xml -DskipTests clean package"
    mvn  -f ${__project_dir}/pom.xml -DskipTests ${__build_param} clean package
}



function start_spring_app {
    local __app_name=${1}
    local __app_path="$BASEDIR/projects/${__app_name}/target/${__app_name}.jar"
    java -jar $__app_path > $BASEDIR/spring.log &
    until $(curl -s $URL > /dev/null 2>&1)
    do
        sleep 1
    done
}

###new
function start_quarkus_app {
    local __app_name=${1}
    local __app_path="$BASEDIR/projects/${__app_name}/target/${__app_name}-runner"
    $__app_path > $BASEDIR/quarkus.log &

    until $(curl -s $URL > /dev/null 2>&1)
    do
        sleep 0.1
    done
}


function start_vertx_app {
    local __app_name=${1}
    local __app_path="$BASEDIR/projects/${__app_name}/target/${__app_name}.jar"
    java -jar $__app_path > $BASEDIR/vertx.log &
    until $(curl -s $URL > /dev/null 2>&1)
    do
        sleep 1
    done
}

function open_jconsole {
    local __app_name=${1}
    jconsole $(jps -l | grep ${__app_name} | grep -v grep | awk '{ print $1 }') &
}

function install_eap {
    mkdir -p target
    test -d $BASEDIR/target/jboss-eap-7.3.0 && rm -rf $BASEDIR/target/jboss-eap-7.3.0
    unzip -q $BASEDIR/installs/$JBOSS_EAP_ZIP_FILE -d target
    pushd target/jboss-eap-7* > /dev/null
    sh bin/add-user.sh -s -u admin -p admin-123
    sh bin/jboss-cli.sh --commands="embed-server,/subsystem=undertow/configuration=handler/file=welcome-content:remove()" > /dev/null
    popd > /dev/null
}

function install_jws {
    mkdir -p target
    test -d $BASEDIR/target/jws-5.0 && rm -rf $BASEDIR/target/jws-5.0
    unzip -q $BASEDIR/installs/$JBOSS_WS_ZIP_FILE -d target
    rm -rf target/jws-5*/tomcat/webapps/ROOT*
}

function start_eap {
    pushd target/jboss-eap-7* > /dev/null
    sh bin/standalone.sh > /dev/null 2>&1 &
    until $(curl -s $URL > /dev/null 2>&1)
    do
        sleep 1
    done
    popd > /dev/null
}

function start_jws {
    pushd target/jws-5* > /dev/null
    sh tomcat/bin/catalina.sh run > /dev/null 2>&1 &
    until $(curl -s $URL > /dev/null 2>&1)
    do
        sleep 1
    done
    popd > /dev/null
}

function deploy_war {
    local __app_name=${1}
    local __warfile="$BASEDIR/projects/${__app_name}/target/${__app_name}.war"
    local __fullpath_warfile="$(cd $(dirname $__warfile) && pwd)/$(basename $__warfile)"
    pushd target/jboss-eap-7* > /dev/null
    bin/jboss-cli.sh -c --command="deploy $__fullpath_warfile" | grep -iq "success"
    popd > /dev/null
}

function deploy_war_jws {
    local __app_name=${1}
    local __warfile="$BASEDIR/projects/${__app_name}/target/${__app_name}.war"
    local __fullpath_warfile="$(cd $(dirname $__warfile) && pwd)/$(basename $__warfile)"
    pushd target/jws-5* > /dev/null
    cp "$__fullpath_warfile" tomcat/webapps/ROOT.war
    popd > /dev/null
}

function run_springboot {
    local __project="greeting-spring-boot"
    local __app_name=${__project}

    action "Build project ${__project}" "mvn_build_project ${__project}"

    action "Waiting for spring boot to start" "start_spring_app ${__project}"

    action "Open Java Console" "open_jconsole ${__app_name}"

    action "Warmup the server" "ab -k -n $NUM_OF_KILO_CALLS -c 1 -s 120 $URL > warmup.txt 2>&1"

    action "Waiting for the warmup to cool off" "sleep 10"

    action "Running performance test" "ab -k -n $NUM_OF_CALLS -c $NUM_OF_USERS -s 120 $URL > performance.txt 2>&1"

    action "Waiting for the performance test to cool off" "sleep 30"

    action "Stopping the server" "kill $(ps -ef | grep ${__app_name} | grep -v grep | awk '{ print $2 }') > /dev/null"
}

function run_quarkus {
    local __project="greeting-quarkus"
    local __app_name=${__project}

    action "Build project ${__project}" "mvn_build_project ${__project} -Pnative"
    
    action "Waiting for Quarkus to start" "start_quarkus_app ${__project}"

    local __PID=$(ps -ef | grep ${__app_name} | grep -v grep | awk '{ print $2 }')
    
    echo  "Memory consumption"
    local __mem=$(ps -o pid,user,rss,command ax | grep $__PID | grep -v grep | awk '{print $1}')
    echo ${__mem} k
    action "Warmup the server" "ab -k -n $NUM_OF_KILO_CALLS -c 1 -s 120 ${URL}/hello > warmup.txt 2>&1"

    action "Waiting for the warmup to cool off" "sleep 10"

    action "Running performance test" "ab -k -n $NUM_OF_CALLS -c $NUM_OF_USERS -s 120 ${URL}/hello > performance.txt 2>&1"

    echo  "Memory consumption after"
    __mem=$(ps -o pid,user,rss,command ax | grep $__PID | grep -v grep | awk '{print $1}')
    echo ${__mem} k

    action "Waiting for the performance test to cool off" "sleep 1"

    action "Stopping the server" "kill $(ps -ef | grep ${__app_name} | grep -v grep | awk '{ print $2 }') > /dev/null"
}

function run_vertx {
    local __project="greeting-vertx"
    local __app_name=${__project}

    action "Build project ${__project}" "mvn_build_project ${__project}"

    action "Waiting for vertx to start" "start_vertx_app ${__project}"

    action "Open Java Console" "open_jconsole ${__app_name}"

    action "Warmup the server" "ab -k -n $NUM_OF_KILO_CALLS -c 1 -s 120 $URL > warmup.txt 2>&1"

    action "Waiting for the warmup to cool off" "sleep 10"

    action "Running performance test" "ab -k -n $NUM_OF_CALLS -c $NUM_OF_USERS -s 120 $URL > performance.txt 2>&1"

    action "Waiting for the performance test to cool off" "sleep 30"

    action "Stopping the server" "kill $(ps -ef | grep ${__app_name} | grep -v grep | awk '{ print $2 }') > /dev/null"
}

function run_jboss_eap_spring {
    local __project="greeting-spring"
    local __app_name="jboss-eap"

    action "Building project ${__project}" "mvn_build_project ${__project}"

    action "Installing JBoss EAP" "install_eap"

    action "Start JBoss EAP" "start_eap"

    action "Deploying the ${__project}.war to JBoss EAP" "deploy_war ${__project}"

    action "Open Java Console" "open_jconsole ${__app_name}"

    action "Warmup the server" "ab -k -n $NUM_OF_KILO_CALLS -c 1 -s 120 $URL > warmup.txt 2>&1"

    action "Waiting for the warmup to cool off" "sleep 10"

    action "Running performance test" "ab -k -n $NUM_OF_CALLS -c $NUM_OF_USERS -s 120 $URL > performance.txt 2>&1"

    action "Waiting for the performance test to cool off" "sleep 30"

    action "Stopping the server" "kill $(jps -l | grep ${__app_name} | grep -v grep | awk '{ print $1 }') > /dev/null"
}

function run_jws_spring {
    local __project="greeting-spring"
    local __app_name="org.apache.catalina.startup.Bootstrap"

    action "Building project ${__project}" "mvn_build_project ${__project}"

    action "Installing JBoss Web Server" "install_jws"

    action "Start JBoss Web Server" "start_jws"

    action "Deploying the ${__project}.war to JBoss Web Server" "deploy_war_jws ${__project}"

    action "Open Java Console" "open_jconsole ${__app_name}"

    action "Warmup the server" "ab -k -n $NUM_OF_KILO_CALLS -c 1 -s 120 $URL > warmup.txt 2>&1"

    action "Waiting for the warmup to cool off" "sleep 10"

    action "Running performance test" "ab -k -n $NUM_OF_CALLS -c $NUM_OF_USERS -s 120 $URL > performance.txt 2>&1"

    action "Waiting for the performance test to cool off" "sleep 30"

    action "Stopping the server" "kill $(jps -l | grep ${__app_name} | grep -v grep | awk '{ print $1 }') > /dev/null"
}

function run_jboss_eap_javaee {
    local __project="greeting-javaee"
    local __app_name="jboss-eap"

    action "Building project ${__project}" "mvn_build_project ${__project}"

    action "Installing JBoss EAP" "install_eap"

    action "Start JBoss EAP" "start_eap"

    action "Deploying the ${__project}.war to JBoss EAP" "deploy_war ${__project}"

    action "Open Java Console" "open_jconsole ${__app_name}"

    action "Warmup the server" "ab -k -n $NUM_OF_KILO_CALLS -c 1 -s 120 $URL > warmup.txt 2>&1"

    action "Waiting for the warmup to cool off" "sleep 10"

    action "Running performance test" "ab -k -n $NUM_OF_CALLS -c $NUM_OF_USERS -s 120 $URL > performance.txt 2>&1"

    action "Waiting for the performance test to cool off" "sleep 30"

    action "Stopping the server" "kill $(jps -l | grep ${__app_name} | grep -v grep | awk '{ print $1 }') > /dev/null"

}

function help {
        local command_name=$1
        echo "Valid commands:"
        echo "$command_name spring-boot      # [Runs as a Spring Boot Fat JAR]"
        echo "$command_name vertx            # [Runs as a Eclipse Vert.x Fat JAR]"
        echo "$command_name jws              # [Runs JBoss Web Server]"
        echo "$command_name quarkus          # [Runs Quarkus]"
        echo "$command_name jboss-eap-spring # [Runs JBoss EAP with Spring app]"
        echo "$command_name jboss-eap-javaee # [Runs JBoss EAP with Java EE app]"
        echo "$command_name kill-all         # [Stops all servers]"
}

function not_implemented_yet {
    echo "This feature has not been implemented yet"
}

if [[ $# -gt 0 ]]
then
   key="$1"
   case $key in
      spring-boot)
        shift # past argument
        run_springboot "$@"
        ;;
      quarkus)
        shift # past argument
        run_quarkus "$@"
        ;;
      vertx)
        shift # past argument
        run_vertx "$@"
        ;;
      jws)
        shift # past argument
        run_jws_spring "$@"
        ;;
      jboss-eap-spring)
        shift # past argument
        run_jboss_eap_spring "$@"
        ;;
      jboss-eap-javaee)
        shift # past argument
        run_jboss_eap_javaee "$@"
        ;;
      kill-all)
        shift # past argument
        not_implemented_yet
        ;;
      *)
        # unknown option
        echo "Unknown option."
        help `basename $0`
        ;;
   esac
else
   help `basename $0`
fi
