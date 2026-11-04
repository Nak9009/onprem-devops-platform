// jenkins/shared-library/vars/updateGitOpsRepo.groovy
// Jenkins Shared Library step that clones the GitLab GitOps repository using
// a least-privilege deploy token, updates the Kustomize overlay image tag,
// and commits/pushes the change so Argo CD can synchronize the cluster.
//
// Security Guardrail: Jenkins never runs kubectl or holds Kubernetes cluster-admin credentials.

def call(Map config = [:]) {
    def gitopsRepoUrl = config.gitopsRepoUrl ?: error("gitopsRepoUrl is required")
    def credentialsId = config.credentialsId ?: 'gitlab-gitops-token'
    def appName       = config.appName       ?: error("appName is required")
    def targetEnv     = config.environment   ?: 'dev'
    def imageName     = config.imageName     ?: error("imageName is required")
    def imageTag      = config.imageTag      ?: error("imageTag is required")
    def commitSha     = config.commitSha     ?: 'unknown'

    if (imageTag == 'latest') {
        error("[SECURITY POLICY VIOLATION] Deploying the mutable 'latest' tag is forbidden. Use an immutable tag.")
    }

    withCredentials([usernamePassword(
        credentialsId: credentialsId,
        usernameVariable: 'GITOPS_USER',
        passwordVariable: 'GITOPS_TOKEN'
    )]) {
        sh """
            set -euo pipefail
            rm -rf gitops-checkout
            AUTH_URL=\$(echo "${gitopsRepoUrl}" | sed "s#://#://\${GITOPS_USER}:\${GITOPS_TOKEN}@#")

            git -c http.sslVerify=false clone --branch main "\${AUTH_URL}" gitops-checkout
            cd gitops-checkout

            OVERLAY_PATH="applications/${appName}/overlays/${targetEnv}"
            if [ ! -d "\${OVERLAY_PATH}" ]; then
                echo "[ERROR] GitOps overlay path not found: \${OVERLAY_PATH}" >&2
                exit 1
            fi

            cd "\${OVERLAY_PATH}"
            sed -i.bak -E "s|(newTag:[[:space:]]*).*|\\1\\"${imageTag}\\"|g" kustomization.yaml
            rm -f kustomization.yaml.bak

            git config user.name "Jenkins GitOps Bot"
            git config user.email "jenkins-bot@devops.local"

            if git diff --quiet kustomization.yaml; then
                echo "[INFO] Image tag ${imageTag} is already set in \${OVERLAY_PATH}/kustomization.yaml"
            else
                git add kustomization.yaml
                git commit -m "chore(${appName}/${targetEnv}): promote ${imageName}:${imageTag} (source commit ${commitSha})"
                git -c http.sslVerify=false push origin main
                echo "[OK] Committed and pushed ${imageName}:${imageTag} to GitOps overlay (${targetEnv})."
            fi
        """
    }
}

