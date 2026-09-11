# ============================================================
# meting-api 自建服务镜像（PHP 8.2 + Apache）
# ------------------------------------------------------------
# 背景：injahow/meting-api 官方没有 Docker 镜像、也不读环境变量，
#       所有开关都写在 index.php 顶部（AUTH / CACHE / API_URI 等）。
#       因此这里基于官方 php 镜像自行构建，只补一个 bcmath 扩展
#      （curl / openssl / json 官方镜像已内置）。
#
# 构建前需先把源码放到同目录：
#   git clone --depth 1 https://github.com/injahow/meting-api.git
# ============================================================
FROM php:8.2-apache

# Meting.php 的签名/加密逻辑依赖 bcmath
RUN docker-php-ext-install bcmath

# ★ 关键：Meting.php（2019 年的代码）在 PHP 8.2 下会抛 Deprecated/Warning
#   （如 "Creation of dynamic property Metowolf\Meting::$temp is deprecated"）。
#   而 index.php 靠 header('Location: ...') 做 302 跳转到音频地址，
#   一旦警告被输出到响应体，header 就会失败 → 播放列表能拿到、但点了没声音。
#   这里关闭 display_errors 并压低错误级别，错误转存到容器日志便于排查。
RUN printf '%s\n' \
        'display_errors = Off' \
        'display_startup_errors = Off' \
        'error_reporting = E_ALL & ~E_DEPRECATED & ~E_NOTICE & ~E_WARNING & ~E_STRICT' \
        'log_errors = On' \
        'error_log = /dev/stderr' \
        > /usr/local/etc/php/conf.d/zz-meting.ini

# index.php 必须位于站点根目录，且同目录下要有 public/ 与 src/
COPY meting-api/ /var/www/html/

# 播放列表文件缓存目录（仅当 index.php 里 CACHE=true 时才用到）
RUN mkdir -p /var/www/html/cache/playlist \
    && chown -R www-data:www-data /var/www/html/cache

EXPOSE 80
