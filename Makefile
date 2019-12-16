SHELL := /bin/bash
# amazee.io lagoon Makefile The main purpose of this Makefile is to provide easier handling of
# building images and running tests It understands the relation of the different images (like
# nginx-drupal is based on nginx) and builds them in the correct order Also it knows which
# services in docker-compose.yml are depending on which base images or maybe even other service
# images
#
# The main commands are:

# make build/<imagename>
# Builds an individual image and all of it's needed parents. Run `make build-list` to get a list of
# all buildable images. Make will keep track of each build image with creating an empty file with
# the name of the image in the folder `build`. If you want to force a rebuild of the image, either
# remove that file or run `make clean`

# make build
# builds all images in the correct order. Uses existing images for layer caching, define via `TAG`
# which branch should be used

# make tests/<testname>
# Runs individual tests. In a nutshell it does:
# 1. Builds all needed images for the test
# 2. Starts needed Lagoon services for the test via docker-compose up
# 3. Executes the test
#
# Run `make tests-list` to see a list of all tests.

# make tests
# Runs all tests together. Can be executed with `-j2` for two parallel running tests

# make up
# Starts all Lagoon Services at once, usefull for local development or just to start all of them.

# make logs
# Shows logs of Lagoon Services (aka docker-compose logs -f)

# make minishift
# Some tests need a full openshift running in order to test deployments and such. This can be
# started via openshift. It will:
# 1. Download minishift cli
# 2. Start an OpenShift Cluster
# 3. Configure OpenShift cluster to our needs

# make minishift/stop
# Removes an OpenShift Cluster

# make minishift/clean
# Removes all openshift related things: OpenShift itself and the minishift cli

#######
####### Default Variables
#######

# Parameter for all `docker build` commands, can be overwritten by passing `DOCKER_BUILD_PARAMS=` via the `-e` option
DOCKER_BUILD_PARAMS := --quiet

# On CI systems like jenkins we need a way to run multiple testings at the same time. We expect the
# CI systems to define an Environment variable CI_BUILD_TAG which uniquely identifies each build.
# If it's not set we assume that we are running local and just call it lagoon.
CI_BUILD_TAG ?= lagoon

# Version and Hash of the OpenShift cli that should be downloaded

MINISHIFT_VERSION := 1.34.1
OPENSHIFT_VERSION := v3.11.0
MINISHIFT_CPUS := 6
MINISHIFT_MEMORY := 8GB
MINISHIFT_DISK_SIZE := 30GB

# Version and Hash of the minikube cli that should be downloaded
K3S_VERSION := v1.17.0-k3s.1
KUBECTL_VERSION := v1.17.0
HELM_VERSION := v3.0.3
MINIKUBE_VERSION := 1.5.2
MINIKUBE_PROFILE := $(CI_BUILD_TAG)-minikube
MINIKUBE_CPUS := 6
MINIKUBE_MEMORY := 2048
MINIKUBE_DISK_SIZE := 30g

K3D_VERSION := 1.4.0
K3D_NAME := k3s-$(CI_BUILD_TAG)

ARCH := $(shell uname | tr '[:upper:]' '[:lower:]')
LAGOON_VERSION := $(shell git describe --tags --exact-match 2>/dev/null || echo development)
# Name of the Branch we are currently in
BRANCH_NAME :=
DEFAULT_ALPINE_VERSION := 3.11
GO_VERSION := 1.13.8

#######
####### Commands
#######
####### List of commands in our Makefile

# Define list of all tests
all-k8s-tests-list:=				features-kubernetes \
														nginx \
														drupal
all-k8s-tests = $(foreach image,$(all-k8s-tests-list),k8s-tests/$(image))

# Run all k8s tests
.PHONY: k8s-tests
k8s-tests: $(all-k8s-tests)

.PHONY: $(all-k8s-tests)
$(all-k8s-tests): k3d kubernetes-test-services-up
		$(MAKE) push-local-registry -j6
		$(eval testname = $(subst k8s-tests/,,$@))
		IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) run --rm tests-kubernetes ansible-playbook --skip-tags="skip-on-kubernetes" /ansible/tests/$(testname).yaml $(testparameter)

# push command of our base images into minishift
push-local-registry-images = $(foreach image,$(base-images) $(base-images-with-versions),[push-local-registry]-$(image))
# tag and push all images
.PHONY: push-local-registry
push-local-registry: $(push-local-registry-images)
# tag and push of each image
.PHONY:
	docker login -u admin -p admin 172.17.0.1:8084
	$(push-local-registry-images)

$(push-local-registry-images):
	$(eval image = $(subst [push-local-registry]-,,$@))
	$(eval image = $(subst __,:,$(image)))
	$(info pushing $(image) to local local-registry)
	if docker inspect $(CI_BUILD_TAG)/$(image) > /dev/null 2>&1; then \
		docker tag $(CI_BUILD_TAG)/$(image) localhost:5000/lagoon/$(image) && \
		docker push localhost:5000/lagoon/$(image) | cat; \
	fi

# Define list of all tests
all-openshift-tests-list:=	features-openshift \
														node \
														drupal \
														drupal-postgres \
														drupal-galera \
														github \
														gitlab \
														bitbucket \
														nginx \
														elasticsearch \
														active-standby
all-openshift-tests = $(foreach image,$(all-openshift-tests-list),openshift-tests/$(image))

.PHONY: openshift-tests
openshift-tests: $(all-openshift-tests)

# Run all tests
.PHONY: tests
tests: k8s-tests openshift-tests

# Wait for Keycloak to be ready (before this no API calls will work)
.PHONY: wait-for-keycloak
wait-for-keycloak:
	$(info Waiting for Keycloak to be ready....)
	grep -m 1 "Config of Keycloak done." <(docker-compose -p $(CI_BUILD_TAG) logs -f keycloak 2>&1)

# Define a list of which Lagoon Services are needed for running any deployment testing
main-test-services = broker logs2email logs2slack logs2rocketchat logs2microsoftteams api api-db keycloak keycloak-db ssh auth-server local-git local-api-data-watcher-pusher harbor-core harbor-database harbor-jobservice harbor-portal harbor-nginx harbor-redis harborregistry harborregistryctl harborclair harborclairadapter local-minio

# Define a list of which Lagoon Services are needed for openshift testing
openshift-test-services = openshiftremove openshiftbuilddeploy openshiftbuilddeploymonitor openshiftmisc tests-openshift

# Define a list of which Lagoon Services are needed for kubernetes testing
kubernetes-test-services = kubernetesbuilddeploy kubernetesdeployqueue kubernetesbuilddeploymonitor kubernetesjobs kubernetesjobsmonitor kubernetesremove kubernetesmisc tests-kubernetes local-registry local-dbaas-provider drush-alias

# List of Lagoon Services needed for webhook endpoint testing
webhooks-test-services = webhook-handler webhooks2tasks backup-handler

# List of Lagoon Services needed for drupal testing
drupal-test-services = drush-alias

# All tests that use Webhook endpoints
webhook-tests = github gitlab bitbucket

# All Tests that use API endpoints
api-tests = node features-openshift features-kubernetes nginx elasticsearch active-standby

# All drupal tests
drupal-tests = drupal drupal-postgres drupal-galera
drupal-dependencies = build\:varnish-drupal build\:solr__5.5-drupal build\:nginx-drupal build\:redis build\:php__7.2-cli-drupal build\:php__7.3-cli-drupal build\:php__7.4-cli-drupal build\:postgres-drupal build\:mariadb-drupal

# These targets are used as dependencies to bring up containers in the right order.
.PHONY: main-test-services-up
main-test-services-up: $(foreach image,$(main-test-services),build\:$(image))
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) up -d $(main-test-services)
	$(MAKE) wait-for-keycloak

.PHONY: openshift-test-services-up
openshift-test-services-up: main-test-services-up $(foreach image,$(openshift-test-services),build\:$(image))
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) up -d $(openshift-test-services)

.PHONY: kubernetes-test-services-up
kubernetes-test-services-up: main-test-services-up $(foreach image,$(kubernetes-test-services),build\:$(image))
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) up -d $(kubernetes-test-services)

.PHONY: drupaltest-services-up
drupaltest-services-up: main-test-services-up $(foreach image,$(drupal-test-services),build\:$(image))
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) up -d $(drupal-test-services)

.PHONY: webhooks-test-services-up
webhooks-test-services-up: main-test-services-up $(foreach image,$(webhooks-test-services),build\:$(image))
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) up -d $(webhooks-test-services)

.PHONY: local-registry-up
local-registry-up: build\:local-registry
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) up -d local-registry

openshift-run-api-tests = $(foreach image,$(api-tests),openshift-tests/$(image))
.PHONY: $(openshift-run-api-tests)
$(openshift-run-api-tests): minishift build\:oc-build-deploy-dind openshift-test-services-up push-minishift
		$(eval testname = $(subst openshift-tests/,,$@))
		IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) run --rm tests-openshift ansible-playbook /ansible/tests/$(testname).yaml $(testparameter)

openshift-run-drupal-tests = $(foreach image,$(drupal-tests),openshift-tests/$(image))
.PHONY: $(openshift-run-drupal-tests)
$(openshift-run-drupal-tests): minishift build\:oc-build-deploy-dind $(drupal-dependencies) openshift-test-services-up drupaltest-services-up push-minishift
		$(eval testname = $(subst openshift-tests/,,$@))
		IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) run --rm tests-openshift ansible-playbook /ansible/tests/$(testname).yaml $(testparameter)

openshift-run-webhook-tests = $(foreach image,$(webhook-tests),openshift-tests/$(image))
.PHONY: $(openshift-run-webhook-tests)
$(openshift-run-webhook-tests): minishift build\:oc-build-deploy-dind openshift-test-services-up webhooks-test-services-up push-minishift
		$(eval testname = $(subst openshift-tests/,,$@))
		IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) run --rm tests-openshift ansible-playbook /ansible/tests/$(testname).yaml $(testparameter)


end2end-all-tests = $(foreach image,$(all-tests-list),end2end-tests/$(image))

.PHONY: end2end-tests
end2end-tests: $(end2end-all-tests)

.PHONY: start-end2end-ansible
start-end2end-ansible: build\:tests
		docker-compose -f docker-compose.yaml -f docker-compose.end2end.yaml -p end2end up -d tests

$(end2end-all-tests): start-end2end-ansible
		$(eval testname = $(subst end2end-tests/,,$@))
		docker exec -i $$(docker-compose -f docker-compose.yaml -f docker-compose.end2end.yaml -p end2end ps -q tests) ansible-playbook /ansible/tests/$(testname).yaml

end2end-tests/clean:
		docker-compose -f docker-compose.yaml -f docker-compose.end2end.yaml -p end2end down -v

push-docker-host-image: minishift build\:docker-host minishift/login-docker-registry
	docker tag $(CI_BUILD_TAG)/docker-host $$(cat minishift):30000/lagoon/docker-host
	docker push $$(cat minishift):30000/lagoon/docker-host | cat

lagoon-kickstart: $(foreach image,$(deployment-test-services-rest),build\:$(image))
	IMAGE_REPO=$(CI_BUILD_TAG) CI=false docker-compose -p $(CI_BUILD_TAG) up -d $(deployment-test-services-rest)
	sleep 30
	curl -X POST http://localhost:5555/deploy -H 'content-type: application/json' -d '{ "projectName": "lagoon", "branchName": "master" }'
	make logs

# Show Lagoon Service Logs
logs:
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) logs --tail=10 -f $(service)

# Start all Lagoon Services
up:
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) up -d
	grep -m 1 ".opendistro_security index does not exist yet" <(docker-compose -p $(CI_BUILD_TAG) logs -f logs-db 2>&1)
	while ! docker exec "$$(docker-compose -p $(CI_BUILD_TAG) ps -q logs-db)" ./securityadmin_demo.sh; do sleep 5; done
	$(MAKE) wait-for-keycloak

down:
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) down -v --remove-orphans

# kill all containers containing the name "lagoon"
kill:
	docker ps --format "{{.Names}}" | grep lagoon | xargs -t -r -n1 docker rm -f -v

.PHONY: openshift
openshift:
	$(info the openshift command has been renamed to minishift)

# Start Local OpenShift Cluster within a docker machine with a given name, also check if the IP
# that has been assigned to the machine is not the default one and then replace the IP in the yaml files with it
minishift: local-dev/minishift/minishift
	$(info starting minishift $(MINISHIFT_VERSION) with name $(CI_BUILD_TAG))
ifeq ($(ARCH), darwin)
	./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) start --docker-opt "bip=192.168.89.1/24" --host-only-cidr "192.168.42.1/24" --cpus $(MINISHIFT_CPUS) --memory $(MINISHIFT_MEMORY) --disk-size $(MINISHIFT_DISK_SIZE) --vm-driver virtualbox --openshift-version="$(OPENSHIFT_VERSION)"
else
	./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) start --docker-opt "bip=192.168.89.1/24" --cpus $(MINISHIFT_CPUS) --memory $(MINISHIFT_MEMORY) --disk-size $(MINISHIFT_DISK_SIZE) --openshift-version="$(OPENSHIFT_VERSION)"
endif
	./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) openshift component add service-catalog
ifeq ($(ARCH), darwin)
	@OPENSHIFT_MACHINE_IP=$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip); \
	echo "replacing IP in local-dev/api-data/02-populate-api-data-openshift.gql and docker-compose.yaml with the IP '$$OPENSHIFT_MACHINE_IP'"; \
	sed -i '' -E "s/192.168\.[0-9]{1,3}\.([2-9]|[0-9]{2,3})/$${OPENSHIFT_MACHINE_IP}/g" local-dev/api-data/02-populate-api-data-openshift.gql docker-compose.yaml;
else
	@OPENSHIFT_MACHINE_IP=$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip); \
	echo "replacing IP in local-dev/api-data/02-populate-api-data-openshift.gql and docker-compose.yaml with the IP '$$OPENSHIFT_MACHINE_IP'"; \
	sed -i "s/192.168\.[0-9]\{1,3\}\.\([2-9]\|[0-9]\{2,3\}\)/$${OPENSHIFT_MACHINE_IP}/g" local-dev/api-data/02-populate-api-data-openshift.gql docker-compose.yaml;
endif
	./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ssh --  '/bin/sh -c "sudo sysctl -w vm.max_map_count=262144"'
	eval $$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) oc-env); \
	oc login -u system:admin; \
	bash -c "echo '{\"apiVersion\":\"v1\",\"kind\":\"Service\",\"metadata\":{\"name\":\"docker-registry-external\"},\"spec\":{\"ports\":[{\"port\":5000,\"protocol\":\"TCP\",\"targetPort\":5000,\"nodePort\":30000}],\"selector\":{\"docker-registry\":\"default\"},\"sessionAffinity\":\"None\",\"type\":\"NodePort\"}}' | oc --context="myproject/$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip | sed 's/\./-/g'):8443/system:admin" create -n default -f -"; \
	oc --context="myproject/$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip | sed 's/\./-/g'):8443/system:admin" adm policy add-cluster-role-to-user cluster-admin system:anonymous; \
	oc --context="myproject/$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip | sed 's/\./-/g'):8443/system:admin" adm policy add-cluster-role-to-user cluster-admin developer;
	@echo "$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip)" > $@
	@echo "wait 60secs in order to give openshift time to setup it's registry"
	sleep 60
	eval $$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) oc-env); \
	for i in {10..30}; do oc --context="myproject/$$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) ip | sed 's/\./-/g'):8443/system:admin" patch pv pv00$${i} -p '{"spec":{"storageClassName":"bulk"}}'; done;

.PHONY: minishift/start
minishift/start: minishift minishift/configure-lagoon-local push-docker-host-image

.PHONY: minishift/login-docker-registry
minishift/login-docker-registry: minishift
	eval $$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) oc-env); \
	oc login --insecure-skip-tls-verify -u developer -p developer $$(cat minishift):8443; \
	oc whoami -t | docker login --username developer --password-stdin $$(cat minishift):30000

# Configures an openshift to use with Lagoon
.PHONY: openshift-lagoon-setup
openshift-lagoon-setup:
# Only use the minishift provided oc if we don't have one yet (allows system engineers to use their own oc)
	if ! which oc; then eval $$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) oc-env); fi; \
	oc -n default set env dc/router -e ROUTER_LOG_LEVEL=info -e ROUTER_SYSLOG_ADDRESS=router-logs.lagoon.svc:5140; \
	oc new-project lagoon; \
	oc adm pod-network make-projects-global lagoon; \
	oc -n lagoon create serviceaccount openshiftbuilddeploy; \
	oc -n lagoon policy add-role-to-user admin -z openshiftbuilddeploy; \
	oc -n lagoon create -f openshift-setup/clusterrole-openshiftbuilddeploy.yaml; \
	oc -n lagoon adm policy add-cluster-role-to-user openshiftbuilddeploy -z openshiftbuilddeploy; \
	oc -n lagoon create -f openshift-setup/priorityclasses.yaml; \
	oc -n lagoon create -f openshift-setup/shared-resource-viewer.yaml; \
	oc -n lagoon create -f openshift-setup/policybinding.yaml | oc -n lagoon create -f openshift-setup/rolebinding.yaml; \
	oc -n lagoon create serviceaccount docker-host; \
	oc -n lagoon adm policy add-scc-to-user privileged -z docker-host; \
	oc -n lagoon policy add-role-to-user edit -z docker-host; \
	oc -n lagoon create serviceaccount logs-collector; \
	oc -n lagoon adm policy add-cluster-role-to-user cluster-reader -z logs-collector; \
	oc -n lagoon adm policy add-scc-to-user hostaccess -z logs-collector; \
	oc -n lagoon adm policy add-scc-to-user privileged -z logs-collector; \
	oc -n lagoon adm policy add-cluster-role-to-user daemonset-admin -z lagoon-deployer; \
	oc -n lagoon create serviceaccount lagoon-deployer; \
	oc -n lagoon policy add-role-to-user edit -z lagoon-deployer; \
	oc -n lagoon create -f openshift-setup/clusterrole-daemonset-admin.yaml; \
	oc -n lagoon adm policy add-cluster-role-to-user daemonset-admin -z lagoon-deployer; \
	bash -c "oc process -n lagoon -f services/docker-host/docker-host.yaml | oc -n lagoon apply -f -"; \
	oc -n lagoon create -f openshift-setup/dbaas-roles.yaml; \
	oc -n dbaas-operator-system create -f openshift-setup/dbaas-operator.yaml; \
	oc -n lagoon create -f openshift-setup/dbaas-providers.yaml; \
	oc -n lagoon create -f openshift-setup/dioscuri-roles.yaml; \
	oc -n dioscuri-controller create -f openshift-setup/dioscuri-operator.yaml; \
	echo -e "\n\nAll Setup, use this token as described in the Lagoon Install Documentation:" \
	oc -n lagoon serviceaccounts get-token openshiftbuilddeploy


# This calls the regular openshift-lagoon-setup first, which configures our minishift like we configure a real openshift for lagoon.
# It then overwrites the docker-host deploymentconfig and cronjobs to use our own just-built docker-host images.
.PHONY: minishift/configure-lagoon-local
minishift/configure-lagoon-local: minishift openshift-lagoon-setup
	eval $$(./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) oc-env); \
	bash -c "oc process -n lagoon -p SERVICE_IMAGE=172.30.1.1:5000/lagoon/docker-host:latest -p REPOSITORY_TO_UPDATE=lagoon -f services/docker-host/docker-host.yaml | oc -n lagoon apply -f -"; \
	oc -n default set env dc/router -e ROUTER_LOG_LEVEL=info -e ROUTER_SYSLOG_ADDRESS=172.17.0.1:5140;

# Stop MiniShift
.PHONY: minishift/stop
minishift/stop: local-dev/minishift/minishift
	./local-dev/minishift/minishift --profile $(CI_BUILD_TAG) delete --force
	rm -f minishift

# Stop All MiniShifts
.PHONY: minishift/stopall
minishift/stopall: local-dev/minishift/minishift
	for profile in $$(./local-dev/minishift/minishift profile list | awk '{ print $$2 }'); do ./local-dev/minishift/minishift --profile $$profile delete --force; done
	rm -f minishift

# Stop MiniShift, remove downloaded minishift
.PHONY: minishift/clean
minishift/clean: minishift/stop
	rm -rf ./local-dev/minishift/minishift

# Stop All Minishifts, remove downloaded minishift
.PHONY: openshift/cleanall
minishift/cleanall: minishift/stopall
	rm -rf ./local-dev/minishift/minishift

# Symlink the installed minishift client if the correct version is already
# installed, otherwise downloads it.
local-dev/minishift/minishift:
	@mkdir -p ./local-dev/minishift
ifeq ($(MINISHIFT_VERSION), $(shell minishift version 2>/dev/null | sed -E 's/^minishift v([0-9.]+).*/\1/'))
	$(info linking local minishift version $(MINISHIFT_VERSION))
	ln -s $(shell command -v minishift) ./local-dev/minishift/minishift
else
	$(info downloading minishift version $(MINISHIFT_VERSION) for $(ARCH))
	curl -L https://github.com/minishift/minishift/releases/download/v$(MINISHIFT_VERSION)/minishift-$(MINISHIFT_VERSION)-$(ARCH)-amd64.tgz | tar xzC local-dev/minishift --strip-components=1
endif

# Symlink the installed k3d client if the correct version is already
# installed, otherwise downloads it.
local-dev/k3d:
ifeq ($(K3D_VERSION), $(shell k3d version 2>/dev/null | grep k3d | sed -E 's/^k3d version v([0-9.]+).*/\1/'))
	$(info linking local k3d version $(K3D_VERSION))
	ln -s $(shell command -v k3d) ./local-dev/k3d
else
	$(info downloading k3d version $(K3D_VERSION) for $(ARCH))
	curl -Lo local-dev/k3d https://github.com/rancher/k3d/releases/download/v$(K3D_VERSION)/k3d-$(ARCH)-amd64
	chmod a+x local-dev/k3d
endif

# Symlink the installed kubectl client if the correct version is already
# installed, otherwise downloads it.
local-dev/kubectl:
ifeq ($(KUBECTL_VERSION), $(shell kubectl version --short --client 2>/dev/null | sed -E 's/Client Version: v([0-9.]+).*/\1/'))
	$(info linking local kubectl version $(KUBECTL_VERSION))
	ln -s $(shell command -v kubectl) ./local-dev/kubectl
else
	$(info downloading kubectl version $(KUBECTL_VERSION) for $(ARCH))
	curl -Lo local-dev/kubectl https://storage.googleapis.com/kubernetes-release/release/$(KUBECTL_VERSION)/bin/$(ARCH)/amd64/kubectl
	chmod a+x local-dev/kubectl
endif

# Symlink the installed helm client if the correct version is already
# installed, otherwise downloads it.
local-dev/helm/helm:
	@mkdir -p ./local-dev/helm
ifeq ($(HELM_VERSION), $(shell helm version --short --client 2>/dev/null | sed -E 's/v([0-9.]+).*/\1/'))
	$(info linking local helm version $(HELM_VERSION))
	ln -s $(shell command -v helm) ./local-dev/helm
else
	$(info downloading helm version $(HELM_VERSION) for $(ARCH))
	curl -L https://get.helm.sh/helm-$(HELM_VERSION)-$(ARCH)-amd64.tar.gz | tar xzC local-dev/helm --strip-components=1
	chmod a+x local-dev/helm/helm
endif

k3d: local-dev/k3d local-dev/kubectl local-dev/helm/helm build\:docker-host
	$(MAKE) local-registry-up
	$(info starting k3d with name $(K3D_NAME))
	$(info Creating Loopback Interface for docker gateway if it does not exist, this might ask for sudo)
ifeq ($(ARCH), darwin)
	if ! ifconfig lo0 | grep $$(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}') -q; then sudo ifconfig lo0 alias $$(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}'); fi
endif
	./local-dev/k3d create --wait 0 --publish 18080:80 \
		--publish 18443:443 \
		--api-port 16643 \
		--name $(K3D_NAME) \
		--image docker.io/rancher/k3s:$(K3S_VERSION) \
		--volume $$PWD/local-dev/k3d-registries.yaml:/etc/rancher/k3s/registries.yaml \
		-x --no-deploy=traefik \
		--volume $$PWD/local-dev/k3d-nginx-ingress.yaml:/var/lib/rancher/k3s/server/manifests/k3d-nginx-ingress.yaml
	echo "$(K3D_NAME)" > $@
	export KUBECONFIG="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')"; \
	local-dev/kubectl apply -f $$PWD/local-dev/k3d-storageclass-bulk.yaml; \
	docker tag $(CI_BUILD_TAG)/docker-host localhost:5000/lagoon/docker-host; \
	docker push localhost:5000/lagoon/docker-host; \
	local-dev/kubectl create namespace lagoon; \
	local-dev/helm/helm upgrade --install -n lagoon lagoon-remote ./charts/lagoon-remote --set dockerHost.image.name=172.17.0.1:5000/lagoon/docker-host --set dockerHost.registry=172.17.0.1:5000; \
	local-dev/kubectl -n lagoon rollout status deployment docker-host -w;
ifeq ($(ARCH), darwin)
	export KUBECONFIG="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')"; \
	KUBERNETESBUILDDEPLOY_TOKEN=$$(local-dev/kubectl -n lagoon describe secret $$(local-dev/kubectl -n lagoon get secret | grep kubernetesbuilddeploy | awk '{print $$1}') | grep token: | awk '{print $$2}'); \
	sed -i '' -e "s/\".*\" # make-kubernetes-token/\"$${KUBERNETESBUILDDEPLOY_TOKEN}\" # make-kubernetes-token/g" local-dev/api-data/03-populate-api-data-kubernetes.gql; \
	DOCKER_IP="$$(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}')"; \
	sed -i '' -e "s/172\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/$${DOCKER_IP}/g" local-dev/api-data/03-populate-api-data-kubernetes.gql docker-compose.yaml;
else
	export KUBECONFIG="$$(./local-dev/k3d get-kubeconfig --name='$(K3D_NAME)')"; \
	KUBERNETESBUILDDEPLOY_TOKEN=$$(local-dev/kubectl -n lagoon describe secret $$(local-dev/kubectl -n lagoon get secret | grep kubernetesbuilddeploy | awk '{print $$1}') | grep token: | awk '{print $$2}'); \
	sed -i "s/\".*\" # make-kubernetes-token/\"$${KUBERNETESBUILDDEPLOY_TOKEN}\" # make-kubernetes-token/g" local-dev/api-data/03-populate-api-data-kubernetes.gql; \
	DOCKER_IP="$$(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}')"; \
	sed -i "s/172\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/$${DOCKER_IP}/g" local-dev/api-data/03-populate-api-data-kubernetes.gql docker-compose.yaml;
endif
	$(MAKE) push-kubectl-build-deploy-dind

.PHONY: push-kubectl-build-deploy-dind
push-kubectl-build-deploy-dind: build\:kubectl-build-deploy-dind
	docker tag $(CI_BUILD_TAG)/kubectl-build-deploy-dind localhost:5000/lagoon/kubectl-build-deploy-dind
	docker push localhost:5000/lagoon/kubectl-build-deploy-dind

.PHONY: rebuild-push-kubectl-build-deploy-dind
rebuild-push-kubectl-build-deploy-dind: push-kubectl-build-deploy-dind

k3d-kubeconfig:
	export KUBECONFIG="$$(./local-dev/k3d get-kubeconfig --name=$$(cat k3d))"

k3d-dashboard:
	export KUBECONFIG="$$(./local-dev/k3d get-kubeconfig --name=$$(cat k3d))"; \
	local-dev/kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/00_dashboard-namespace.yaml; \
	local-dev/kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/01_dashboard-serviceaccount.yaml; \
	local-dev/kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/02_dashboard-service.yaml; \
	local-dev/kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/03_dashboard-secret.yaml; \
	local-dev/kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/04_dashboard-configmap.yaml; \
	echo '{"apiVersion": "rbac.authorization.k8s.io/v1","kind": "ClusterRoleBinding","metadata": {"name": "kubernetes-dashboard","namespace": "kubernetes-dashboard"},"roleRef": {"apiGroup": "rbac.authorization.k8s.io","kind": "ClusterRole","name": "cluster-admin"},"subjects": [{"kind": "ServiceAccount","name": "kubernetes-dashboard","namespace": "kubernetes-dashboard"}]}' | local-dev/kubectl -n kubernetes-dashboard apply -f - ; \
	local-dev/kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/06_dashboard-deployment.yaml; \
	local-dev/kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/07_scraper-service.yaml; \
	local-dev/kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended/08_scraper-deployment.yaml; \
	local-dev/kubectl -n kubernetes-dashboard patch deployment kubernetes-dashboard --patch '{"spec": {"template": {"spec": {"containers": [{"name": "kubernetes-dashboard","args": ["--auto-generate-certificates","--namespace=kubernetes-dashboard","--enable-skip-login"]}]}}}}'; \
	local-dev/kubectl -n kubernetes-dashboard rollout status deployment kubernetes-dashboard -w; \
	open http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/ ; \
	local-dev/kubectl proxy

k8s-dashboard:
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc2/aio/deploy/recommended.yaml; \
	kubectl -n kubernetes-dashboard rollout status deployment kubernetes-dashboard -w; \
	echo -e "\nUse this token:"; \
	kubectl -n lagoon describe secret $$(local-dev/kubectl -n lagoon get secret | grep kubernetesbuilddeploy | awk '{print $$1}') | grep token: | awk '{print $$2}'; \
	open http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/ ; \
	kubectl proxy

# Stop k3d
.PHONY: k3d/stop
k3d/stop: local-dev/k3d
	./local-dev/k3d delete --name=$$(cat k3d) || true
	rm -f k3d

# Stop All k3d
.PHONY: k3d/stopall
k3d/stopall: local-dev/k3d
	./local-dev/k3d delete --all || true
	rm -f k3d

# Stop k3d, remove downloaded k3d
.PHONY: k3d/clean
k3d/clean: k3d/stop
	rm -rf ./local-dev/k3d

# Stop All k3d, remove downloaded k3d
.PHONY: k3d/cleanall
k3d/cleanall: k3d/stopall
	rm -rf ./local-dev/k3d

# Configures an openshift to use with Lagoon
.PHONY: kubernetes-lagoon-setup
kubernetes-lagoon-setup:
	kubectl create namespace lagoon; \
	local-dev/helm/helm upgrade --install -n lagoon lagoon-remote ./charts/lagoon-remote; \
	echo -e "\n\nAll Setup, use this token as described in the Lagoon Install Documentation:";
	$(MAKE) kubernetes-get-kubernetesbuilddeploy-token

.PHONY: kubernetes-get-kubernetesbuilddeploy-token
kubernetes-get-kubernetesbuilddeploy-token:
	kubectl -n lagoon describe secret $$(kubectl -n lagoon get secret | grep kubernetesbuilddeploy | awk '{print $$1}') | grep token: | awk '{print $$2}'

.PHONY: rebuild-push-oc-build-deploy-dind
rebuild-push-oc-build-deploy-dind: minishift/login-docker-registry build\:oc-build-deploy-dind
	docker tag $(CI_BUILD_TAG)/oc-build-deploy-dind $$(cat minishift):30000/lagoon/oc-build-deploy-dind && docker push $$(cat minishift):30000/lagoon/oc-build-deploy-dind

.PHONY: ui-development
ui-development: build\:api build\:api-db build\:local-api-data-watcher-pusher build\:ui build\:keycloak build\:keycloak-db build\:broker build\:broker-single
	IMAGE_REPO=$(CI_BUILD_TAG) docker-compose -p $(CI_BUILD_TAG) up -d api api-db local-api-data-watcher-pusher ui keycloak keycloak-db broker

#######
####### Container image build system
#######

DOCKERFILES = $(shell find images services local-dev cli tests -type f -name 'Dockerfile*')
DOCKERRULES = .docker.mk
PHP_VERSIONS := 7.2 7.3 7.4
NODE_VERSIONS := 10 12
PYTHON_VERSIONS := 2.7 3.7
SOLR_VERSIONS := 5.5 6.6 7.5
# IMPORTANT: only one of each minor version, as the images are tagged based on minor version
ELASTIC_VERSIONS := 7.1.1 7.2.1 7.3.2

# Build a docker image.
# $1: image name
# $2: Dockerfile path
# $3: docker build context directory
docker_build_cmd = docker build $(DOCKER_BUILD_PARAMS) --build-arg LAGOON_VERSION=$(LAGOON_VERSION) --build-arg IMAGE_REPO=$(CI_BUILD_TAG) --build-arg ALPINE_VERSION=$(DEFAULT_ALPINE_VERSION) -t $(CI_BUILD_TAG)/$(1) -f $(2) $(3)

# Build a docker image with a version build-arg.
# $1: image name
# $2: base image version
# $3: image tag
# $4: Dockerfile path
# $5: docker build context directory
docker_build_version_cmd = docker build $(DOCKER_BUILD_PARAMS) --build-arg LAGOON_VERSION=$(LAGOON_VERSION) --build-arg IMAGE_REPO=$(CI_BUILD_TAG) --build-arg ALPINE_VERSION=$(DEFAULT_ALPINE_VERSION) --build-arg BASE_VERSION=$(2) -t $(CI_BUILD_TAG)/$(1):$(3) -f $(4) $(5)

# Tag an image with the `amazeeio` repository and push it.
# $1: source image name:tag
# $2: target image name:tag
docker_publish_amazeeio = docker tag $(CI_BUILD_TAG)/$(1) amazeeio/$(2) && docker push amazeeio/$(2)

# Tag an image with the `amazeeiolagoon` repository and push it.
# $1: source image name:tag
# $2: target image name:tag
docker_publish_amazeeiolagoon = docker tag $(CI_BUILD_TAG)/$(1) amazeeiolagoon/$(2) && docker push amazeeiolagoon/$(2)

$(DOCKERRULES): $(DOCKERFILES) Makefile docker-build.awk docker-pull.awk
	@# generate build commands for all lagoon docker images
	@(grep '^FROM $${IMAGE_REPO:-.*}/' $(DOCKERFILES); \
		grep -L '^FROM $${IMAGE_REPO:-.*}/' $(DOCKERFILES)) | \
		./docker-build.awk \
		-v PHP_VERSIONS="$(PHP_VERSIONS)" \
		-v NODE_VERSIONS="$(NODE_VERSIONS)" \
		-v PYTHON_VERSIONS="$(PYTHON_VERSIONS)" \
		-v SOLR_VERSIONS="$(SOLR_VERSIONS)" \
		-v ELASTIC_VERSIONS="$(ELASTIC_VERSIONS)" \
		> $@
	@# generate pull commands for all images lagoon builds on
	@grep '^FROM ' $(DOCKERFILES) | \
		grep -v ':FROM $${IMAGE_REPO:-.*}/' | \
		./docker-pull.awk \
		-v PHP_VERSIONS="$(PHP_VERSIONS)" \
		-v NODE_VERSIONS="$(NODE_VERSIONS)" \
		-v PYTHON_VERSIONS="$(PYTHON_VERSIONS)" \
		-v SOLR_VERSIONS="$(SOLR_VERSIONS)" \
		-v ELASTIC_VERSIONS="$(ELASTIC_VERSIONS)" \
		>> $@

include $(DOCKERRULES)
