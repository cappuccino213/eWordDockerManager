#!/bin/bash
# author：zhangyp
# function：Docker Compose应用部署管理工具
# date：2025年2月28日 16:34:57

# ***参数设置***
# 启用严格错误检查
set -eo pipefail
# 初始化全局变量
CURRENT_DIR=$(pwd)
COMPOSE_FILE="$CURRENT_DIR/docker-compose.yml"

# 颜色定义
reset='\033[0m'
red="\033[31m"
green="\033[32m"
yellow="\033[33m"
blue="\033[34m"
magenta="\033[35m"

# 浅色
light_black="\033[90m"
light_red="\033[91m"
light_green="\033[92m"
light_yellow="\033[93m"
light_blue="\033[94m"
light_purple="\033[95m"
light_cyan="\033[96m"
light_white="\033[97m"


# 文字格式
bold="\033[1m"
underline="\033[4m"

# ***函数定义***
# --通用函数--
# 预检查函数
function check_docker_compose() {
    if ! command -v docker-compose &>/dev/null; then
        echo -e "${red}❎ 错误：docker-compose 未安装，请先安装！${reset}"
        return 1
    fi
}

# 检查docker-compose文件
function check_compose_file() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${red}❎ 错误：docker-compose.yml 文件不存在！${reset}"
        return 1
    fi
    if ! docker-compose config -q &>/dev/null; then
        echo -e "${red}❎ 错误：docker-compose.yml 文件格式无效！${reset}"
        return 1
    fi
}

# 从tar载入镜像函数
function load_images() {
    shopt -s nullglob
    local tar_files=("$CURRENT_DIR"/*.tar)
    shopt -u nullglob

    for file in "${tar_files[@]}"; do
        echo -e "${green}➜正在处理：$(basename "$file")${reset}"

#        # 基础验证：是否为合法Docker镜像包
#        if ! tar -tf "$file" | grep -q 'manifest.json'; then
#            echo -e "${yellow}⚠ 警告：非Docker镜像文件（缺少manifest.json），已跳过${reset}"
#            continue
#        fi

        # 尝试提取镜像标签
        local image_tag=""
        if tar -xOf "$file" manifest.json 2>/dev/null | grep -q '"RepoTags"'; then
            # 使用原生解析方案提取镜像标签
            image_tag=$(tar -xOf "$file" manifest.json |
                        grep -o '"RepoTags":\[[^]]*\]' |
                        sed 's/.*"RepoTags":\["\([^"]*\)".*/\1/')
        fi

        # 最终兜底验证
        if [[ -z "$image_tag" ]]; then
            echo -e "${yellow}⚠ 警告：无法提取镜像标签，尝试强制加载...${reset}"
            if docker load -i "$file"; then
                echo -e "${green}✔ 镜像已加载（标签未知）${reset}"
            else
                echo -e "${red}✘ 镜像加载失败，文件可能损坏${reset}"
            fi
            continue
        fi

        # 检查镜像是否存在
        if docker image inspect "$image_tag" &>/dev/null; then
            echo -e "${yellow}⚠ 镜像 $image_tag 已存在，跳过加载${reset}"
        else
            echo -n "加载镜像..."
            if docker load -i "$file" &>/dev/null; then
                echo -e "${green}✔ 成功加载 $image_tag${reset}"
            else
                echo -e "${red}✘ 加载失败${reset}"
                return 1
            fi
        fi
    done
}

# docker-compose创建容器函数
function create_containers() {
    # 从 docker-compose.yml 中提取服务名称
    mapfile -t service_names < <(docker-compose -f "$COMPOSE_FILE" config --services)

    # 获取当前所有容器及其对应的服务名称
    mapfile -t existing_containers < <(docker ps -a --format '{{.Names}}')

    for service_name in "${service_names[@]}"; do
        echo -e "${green}➜ 正在检查服务：$service_name${reset}"

        # 获取服务对应的容器名称
        container_id=$(docker-compose -f "$COMPOSE_FILE" ps -q "$service_name")
        if [[ -n "$container_id" ]]; then
            container_name=$(docker inspect --format '{{.Name}}' "$container_id" | sed 's/^\///')
        else
            container_name=""
        fi

        # 检查服务对应的容器是否已存在
        if [[ -n "$container_name" && " ${existing_containers[*]} " =~ [[:space:]]${container_name}[[:space:]] ]]; then
            echo -e "${yellow}⚠ 服务 $service_name 对应的容器 $container_name 已存在${reset}"

            # 交互式询问是否强制重新创建容器
            read -rp "是否强制重新创建服务 $service_name 的容器？(y/n, 默认跳过): " force_recreate
            force_recreate=${force_recreate:-n}  # 默认值为 'n'

            if [[ "$force_recreate" =~ ^[Yy]$ ]]; then
                echo -e "${blue}ℹ️正在卸载并重新创建服务 $service_name 的容器...${reset}"
                docker-compose -f "$COMPOSE_FILE" up -d --force-recreate "$service_name"  # 强制重新创建容器
                echo -e "${green}✔ 服务 $service_name 的容器已重新创建${reset}"
            else
                echo -e "${blue}ℹ️跳过重新创建服务 $service_name 的容器${reset}"
            fi
        else
            echo -e "${blue}ℹ️服务 $service_name 的容器不存在，正在创建...${reset}"
            docker-compose -f "$COMPOSE_FILE" up -d "$service_name"
            echo -e "${green}✔ 服务 $service_name 的容器已创建${reset}"
        fi
    done
}

# --业务函数--
# -部署功能-
function deploy_app() {
    echo -e "\n${light_blue}${bold}>>>1应用部署>>>${reset}"
    if ! check_docker_compose; then return; fi
    if ! check_compose_file; then return; fi

    # 解析 docker-compose.yml 文件，通过image的路径格式判断是在线拉取镜像还是本地加载
    # 如果image的路径格式是本地加载，调用load_images函数
    # 如果image的路径格式是在线拉取镜像，则不执行任何操作
    if grep -qE '^image:\s*[^/]+/[^/]+' "$COMPOSE_FILE"; then
        echo -e "${blue}ℹ️检测到镜像路径为在线镜像，跳过加载镜像步骤，进行镜像拉取...${reset}"
    else
        echo -e "${blue}ℹ️检测到镜像路径为本地镜像，通过load方式加载镜像...${reset}"
        if ! load_images; then return; fi
    fi

    # 创建容器
    create_containers
}

# -卸载版本-
function uninstall_app() {
    echo -e "\n${light_purple}${bold}>>>2卸载应用>>>${reset}"
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${red}❎ 错误：docker-compose.yml 不存在！${reset}"
        return
    fi

    # 列出所有服务名
    local services=($(docker-compose config --services))
    if [ ${#services[@]} -eq 0 ]; then
        echo -e "${red}❎ 错误：没有找到任何服务！${reset}"
        return
    fi

    echo -e "${green}编号\t运行中的服务${reset}"
    for i in "${!services[@]}"; do
        echo -e "$((i+1))\t${services[$i]}"
    done

    echo -n "请输入要卸载的服务编号（Enter表示卸载所有服务）："
    read -r service_index

    if [ -z "$service_index" ]; then
        echo -n "确定要完全卸载所有服务吗？(y/n) "
        read -r confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            docker-compose down
            echo -e "${green}✔ 所有服务已卸载${reset}"
        else
            echo -e "${blue}操作已取消${reset}"
        fi
    else
        if [[ $service_index =~ ^[0-9]+$ ]] && [ $service_index -ge 1 ] && [ $service_index -le ${#services[@]} ]; then
            service_name=${services[$((service_index-1))]}
            echo -n "确定要卸载服务 '$service_name' 吗？(y/n) "
            read -r confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                docker-compose stop "$service_name"
                docker-compose rm -f "$service_name"
                echo -e "${green}✔ 服务 '$service_name' 已卸载${reset}"
            else
                echo -e "${blue}操作已取消${reset}"
            fi
        else
            echo -e "${red}❎ 错误：无效的服务编号！${reset}"
        fi
    fi
}

# 容器管理子菜单
function container_menu() {
    echo -e "\n${magenta}>>>应用管理/容器管理>>>${reset}"
    local containers=($(docker-compose ps --services))
    # 换成mapfile读取容器名称
    if [ ${#containers[@]} -eq 0 ]; then
        echo -e "${yellow}💡 没有运行中的容器${reset}"
        return
    fi

    echo -e "${green}编号\t容器名称${reset}"
    for i in "${!containers[@]}"; do
        echo -e "$((i+1))\t${containers[$i]}"
    done

    echo -n "请输入要删除的容器编号（q返回）："
    read -r choice
    if [[ "$choice" == "q" ]]; then return; fi

    local index=$((choice-1))
    if [[ $index -ge 0 && $index -lt ${#containers[@]} ]]; then
        echo -n "确定要停止并删除 ${containers[$index]} 吗？(y/N) "
        read -r confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            docker-compose rm -sfv "${containers[$index]}"
            echo -e "${green}✔ 操作完成${reset}"
        fi
    else
        echo -e "${red}🚫无效的编号！${reset}"
    fi
}

# 镜像管理子菜单
function image_menu() {
    echo -e "\n${magenta}>>>应用管理/镜像管理>>>${reset}"
    local images=($(docker images --format "{{.Repository}}:{{.Tag}}"))
    if [ ${#images[@]} -eq 0 ]; then
        echo -e "${yellow}💡 没有可用镜像${reset}"
        return
    fi

    echo -e "${green}编号\t镜像名称${reset}"
    for i in "${!images[@]}"; do
        echo -e "$((i+1))\t${images[$i]}"
    done

    echo -n "请输入要删除的编号（q返回）："
    read -r choice
    if [[ "$choice" == "q" ]]; then return; fi

    local index=$((choice-1))
    if [[ $index -ge 0 && $index -lt ${#images[@]} ]]; then
        echo -n "确定要删除 ${images[$index]} 吗？(y/N) "
        read -r confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            docker rmi -f "${images[$index]}"
            echo -e "${green}✔ 镜像已删除${reset}"
        fi
    else
        echo -e "${red}🚫无效的编号！${reset}"
    fi
}

# -应用管理-
function app_manage() {
    while true; do
        echo -e "\n${light_yellow}${bold}---应用管理---${reset}"
        echo -e "${light_yellow}${bold}● 1 管理容器${reset}"
        echo -e "${light_yellow}${bold}● 2 管理镜像${reset}"
        echo -e "${light_red}${bold}● q 返回主菜单${reset}"
        echo -n "请选择："
        read -r choice

        case $choice in
            1) container_menu ;;
            2) image_menu ;;
            q) break ;;
            *) echo -e "${red}🚫无效选项！${reset}" ;;
        esac
    done
}

# -主菜单-
function main_menu() {
    while true; do
        echo -e "${light_cyan}======================================${reset}"
        echo -e "${light_cyan}${bold}欢迎使用eWord Docker应用部署工具${reset}"
        echo -e "${light_cyan}======================================${reset}"
        echo -e "${light_blue}${bold}🔹🔹🔹1. 部署应用🔹🔹🔹${reset}"
        echo -e "${light_purple}${bold}🔹🔹🔹2. 卸载应用🔹🔹🔹${reset}"
        echo -e "${light_yellow}🔹🔹🔹3. 应用管理🔹🔹🔹${reset}"
        echo -e "${light_red}${bold}🔸🔸🔸q. 退出工具🔸🔸🔸${reset}"
        echo -n "请输入功能编号："
        read -r choice

        case $choice in
            1) deploy_app ;;
            2) uninstall_app ;;
            3) app_manage ;;
            q) echo -e "${blue}再见,期待再次使用！${reset}"; exit 0 ;;
            *) echo -e "${red}🚫无效的编号！${reset}" ;;
        esac
    done
}

# 异常处理
trap 'echo -e "${red}\n操作被中断！返回主菜单...${reset}"; main_menu' SIGINT

# ***主程序调用**
main_menu