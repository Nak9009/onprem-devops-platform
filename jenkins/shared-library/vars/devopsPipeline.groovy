// jenkins/shared-library/vars/devopsPipeline.groovy
// Reusable wrapper step for standardizing CI builds across microservices in the organization.

def call(Map params = [:]) {
    def appName    = params.appName    ?: error("appName is required")
    def appVersion = params.appVersion ?: '1.0.0'

    echo "[DevOps Shared Library] Initialized standard CI pipeline for ${appName} v${appVersion}"
}

