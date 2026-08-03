#!/bin/bash

# =============================================================================
# kiro-deploy.sh — Deploy e Rollback para ambientes ECS do projeto BIA
# =============================================================================

set -e

# ─── Configurações ────────────────────────────────────────────────────────────
REGION="us-east-1"
ECR_REGISTRY="255748959698.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPO="luzia"

# Ambientes
CLUSTER_SEM_ALB="cluster-luzia"
SERVICE_SEM_ALB="service-luzia"
TASK_DEF_SEM_ALB="task-dev-luzia"

CLUSTER_COM_ALB="cluster-luzia-alb"
SERVICE_COM_ALB="service-luzia-alb"
TASK_DEF_COM_ALB="task-dev-luzia-alb"

# ─── Cores para output ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── Funções utilitárias ──────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC} $1"; }
log_step()    { echo -e "\n${BOLD}${CYAN}▶ $1${NC}"; }

separator() { echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"; }

# ─── Validações iniciais ──────────────────────────────────────────────────────
check_dependencies() {
  log_step "Verificando dependências..."

  if ! command -v git &>/dev/null; then
    log_error "git não encontrado. Instale o git e tente novamente."
    exit 1
  fi

  if ! command -v docker &>/dev/null; then
    log_error "docker não encontrado. Instale o Docker e tente novamente."
    exit 1
  fi

  if ! command -v aws &>/dev/null; then
    log_error "aws cli não encontrada. Instale o AWS CLI e tente novamente."
    exit 1
  fi

  if ! git rev-parse --git-dir &>/dev/null; then
    log_error "Este diretório não é um repositório Git. Execute o script a partir da raiz do projeto."
    exit 1
  fi

  if [ ! -f "Dockerfile" ]; then
    log_error "Dockerfile não encontrado. Execute o script a partir da raiz do projeto."
    exit 1
  fi

  log_success "Todas as dependências encontradas."
}

# ─── Menu: Escolha do ambiente ────────────────────────────────────────────────
choose_environment() {
  separator
  echo -e "${BOLD}Qual ambiente deseja usar?${NC}"
  echo ""
  echo "  [1] Sem ALB  →  ${CLUSTER_SEM_ALB} / ${SERVICE_SEM_ALB}"
  echo "  [2] Com ALB  →  ${CLUSTER_COM_ALB} / ${SERVICE_COM_ALB}"
  echo ""
  read -rp "Escolha (1 ou 2): " env_choice

  case $env_choice in
    1)
      CLUSTER=$CLUSTER_SEM_ALB
      SERVICE=$SERVICE_SEM_ALB
      TASK_DEF=$TASK_DEF_SEM_ALB
      ENV_LABEL="Sem ALB"
      ;;
    2)
      CLUSTER=$CLUSTER_COM_ALB
      SERVICE=$SERVICE_COM_ALB
      TASK_DEF=$TASK_DEF_COM_ALB
      ENV_LABEL="Com ALB"
      ;;
    *)
      log_error "Opção inválida. Escolha 1 ou 2."
      exit 1
      ;;
  esac

  log_success "Ambiente selecionado: ${BOLD}${ENV_LABEL}${NC}"
}

# ─── Menu: Escolha da operação ────────────────────────────────────────────────
choose_operation() {
  separator
  echo -e "${BOLD}O que deseja fazer?${NC}"
  echo ""
  echo "  [1] Deploy    →  Build + Push + Atualizar ECS"
  echo "  [2] Rollback  →  Escolher revisão anterior e atualizar ECS"
  echo ""
  read -rp "Escolha (1 ou 2): " op_choice

  case $op_choice in
    1) OPERATION="deploy" ;;
    2) OPERATION="rollback" ;;
    *)
      log_error "Opção inválida. Escolha 1 ou 2."
      exit 1
      ;;
  esac
}

# ─── Deploy ───────────────────────────────────────────────────────────────────
do_deploy() {
  # Captura o short commit hash
  COMMIT_HASH=$(git rev-parse --short HEAD)
  IMAGE_URI="${ECR_REGISTRY}/${ECR_REPO}:${COMMIT_HASH}"

  separator
  log_step "Iniciando deploy"
  log_info "Ambiente  : ${BOLD}${ENV_LABEL}${NC}"
  log_info "Cluster   : ${CLUSTER}"
  log_info "Service   : ${SERVICE}"
  log_info "Task Def  : ${TASK_DEF}"
  log_info "Commit    : ${BOLD}${COMMIT_HASH}${NC}"
  log_info "Imagem    : ${IMAGE_URI}"
  separator

  # Confirmação
  echo ""
  read -rp "Confirmar deploy? (s/N): " confirm
  [[ "$confirm" =~ ^[Ss]$ ]] || { log_warn "Deploy cancelado."; exit 0; }

  # 1. Login no ECR
  log_step "Autenticando no ECR..."
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY"
  log_success "Login no ECR realizado."

  # 2. Build da imagem
  log_step "Fazendo build da imagem Docker..."
  docker build -t "${ECR_REPO}:${COMMIT_HASH}" .
  log_success "Build concluído."

  # 3. Tag e Push
  log_step "Enviando imagem para o ECR..."
  docker tag "${ECR_REPO}:${COMMIT_HASH}" "$IMAGE_URI"
  docker push "$IMAGE_URI"
  log_success "Imagem enviada: ${IMAGE_URI}"

  # 4. Busca a task definition atual para usar como base
  log_step "Buscando task definition atual..."
  TASK_DEF_JSON=$(aws ecs describe-task-definition \
    --task-definition "$TASK_DEF" \
    --region "$REGION" \
    --query "taskDefinition" \
    --output json)

  CONTAINER_NAME=$(echo "$TASK_DEF_JSON" | python3 -c \
    "import sys, json; print(json.load(sys.stdin)['containerDefinitions'][0]['name'])")

  log_info "Container identificado: ${CONTAINER_NAME}"

  # 5. Cria nova revisão da task definition com a nova imagem
  log_step "Registrando nova revisão da task definition..."
  NEW_TASK_DEF=$(echo "$TASK_DEF_JSON" | python3 -c "
import sys, json

td = json.load(sys.stdin)

# Atualiza a imagem do primeiro container
td['containerDefinitions'][0]['image'] = '${IMAGE_URI}'

# Remove campos que não devem ser enviados no registro
for field in ['taskDefinitionArn','revision','status','requiresAttributes',
              'compatibilities','registeredAt','registeredBy']:
    td.pop(field, None)

print(json.dumps(td))
")

  NEW_REVISION=$(aws ecs register-task-definition \
    --region "$REGION" \
    --cli-input-json "$NEW_TASK_DEF" \
    --query "taskDefinition.revision" \
    --output text)

  log_success "Nova revisão registrada: ${BOLD}${TASK_DEF}:${NEW_REVISION}${NC}"

  # 6. Atualiza o serviço ECS
  log_step "Atualizando serviço ECS..."
  aws ecs update-service \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "${TASK_DEF}:${NEW_REVISION}" \
    --output text > /dev/null

  log_success "Serviço atualizado para ${TASK_DEF}:${NEW_REVISION}"

  # 7. Aguarda estabilização
  wait_for_stability

  separator
  log_success "Deploy concluído com sucesso!"
  log_info "Imagem  : ${IMAGE_URI}"
  log_info "Revisão : ${TASK_DEF}:${NEW_REVISION}"
  separator
}

# ─── Rollback ─────────────────────────────────────────────────────────────────
do_rollback() {
  separator
  log_step "Listando revisões disponíveis para rollback"
  log_info "Task Definition: ${TASK_DEF}"
  echo ""

  # Lista todas as revisões ativas
  REVISIONS=$(aws ecs list-task-definitions \
    --region "$REGION" \
    --family-prefix "$TASK_DEF" \
    --status ACTIVE \
    --sort DESC \
    --query "taskDefinitionArns[]" \
    --output json)

  REVISION_COUNT=$(echo "$REVISIONS" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")

  if [ "$REVISION_COUNT" -eq 0 ]; then
    log_error "Nenhuma revisão encontrada para a task definition '${TASK_DEF}'."
    exit 1
  fi

  # Exibe a tabela de revisões
  printf "  ${BOLD}%-6s %-20s %-60s${NC}\n" "Nº" "Revisão" "Imagem"
  separator

  declare -a REVISION_LIST
  INDEX=1

  while IFS= read -r ARN; do
    ARN=$(echo "$ARN" | tr -d '"')
    REV=$(echo "$ARN" | awk -F: '{print $NF}')
    IMAGE=$(aws ecs describe-task-definition \
      --task-definition "$ARN" \
      --region "$REGION" \
      --query "taskDefinition.containerDefinitions[0].image" \
      --output text)

    TAG=$(echo "$IMAGE" | awk -F: '{print $NF}')
    printf "  %-6s %-20s %-60s\n" "[$INDEX]" "${TASK_DEF}:${REV}" "$TAG"
    REVISION_LIST[$INDEX]="${TASK_DEF}:${REV}"
    INDEX=$((INDEX + 1))
  done < <(echo "$REVISIONS" | python3 -c "import sys, json; [print(r) for r in json.load(sys.stdin)]")

  separator
  echo ""
  read -rp "Escolha o número da revisão para rollback: " rev_choice

  if ! [[ "$rev_choice" =~ ^[0-9]+$ ]] || [ "$rev_choice" -lt 1 ] || [ "$rev_choice" -ge "$INDEX" ]; then
    log_error "Opção inválida."
    exit 1
  fi

  TARGET_REVISION="${REVISION_LIST[$rev_choice]}"

  echo ""
  log_info "Revisão selecionada: ${BOLD}${TARGET_REVISION}${NC}"
  read -rp "Confirmar rollback? (s/N): " confirm
  [[ "$confirm" =~ ^[Ss]$ ]] || { log_warn "Rollback cancelado."; exit 0; }

  # Atualiza o serviço
  log_step "Executando rollback para ${TARGET_REVISION}..."
  aws ecs update-service \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$TARGET_REVISION" \
    --output text > /dev/null

  log_success "Serviço atualizado para ${TARGET_REVISION}"

  # Aguarda estabilização
  wait_for_stability

  separator
  log_success "Rollback concluído com sucesso!"
  log_info "Ambiente : ${ENV_LABEL}"
  log_info "Revisão  : ${TARGET_REVISION}"
  separator
}

# ─── Aguarda estabilização do serviço ─────────────────────────────────────────
wait_for_stability() {
  log_step "Aguardando estabilização do serviço ECS..."
  log_info "Isso pode levar alguns minutos..."

  if aws ecs wait services-stable \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --services "$SERVICE" 2>/dev/null; then
    log_success "Serviço estável."
  else
    log_warn "Timeout ao aguardar estabilização. Verifique o status no console AWS."
    log_info "Comando para verificar:"
    echo "  aws ecs describe-services --cluster ${CLUSTER} --services ${SERVICE} --region ${REGION}"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  clear
  separator
  echo -e "  ${BOLD}${CYAN}kiro-deploy.sh${NC} — Deploy e Rollback ECS | Projeto BIA"
  separator

  check_dependencies
  choose_operation
  choose_environment

  case $OPERATION in
    deploy)   do_deploy ;;
    rollback) do_rollback ;;
  esac
}

main
