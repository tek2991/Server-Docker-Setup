# syntax=docker/dockerfile:1
FROM php:8.3-fpm-alpine

# Install system dependencies & libraries required for PHP extensions
RUN apk add --no-cache \
    bash \
    curl \
    git \
    unzip \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    libzip-dev \
    oniguruma-dev \
    icu-dev \
    linux-headers \
    $PHPIZE_DEPS

# Configure and install core PHP extensions
# intl: Mandatory for Filament 5 ICU formatting
# exif: Mandatory for Spatie Media Library image uploads
# gd: Configured with FreeType and JPEG support
# opcache: Essential for PHP performance on low-CPU instances
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        mbstring \
        zip \
        gd \
        bcmath \
        intl \
        exif \
        pcntl \
        opcache

# Install and enable phpredis extension via PECL
RUN pecl install redis \
    && docker-php-ext-enable redis

# Clean up build dependencies to minimize image size
RUN apk del $PHPIZE_DEPS \
    && rm -rf /tmp/pear /var/cache/apk/*

# Install latest Composer from official binary
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Set recommended PHP runtime and OPcache directives
RUN { \
        echo 'opcache.enable=1'; \
        echo 'opcache.memory_consumption=128'; \
        echo 'opcache.interned_strings_buffer=16'; \
        echo 'opcache.max_accelerated_files=10000'; \
        echo 'opcache.revalidate_freq=0'; \
        echo 'opcache.validate_timestamps=1'; \
    } > /usr/local/etc/php/conf.d/docker-php-ext-opcache.ini \
    && { \
        echo 'memory_limit=256M'; \
        echo 'upload_max_filesize=25M'; \
        echo 'post_max_size=30M'; \
        echo 'max_execution_time=120'; \
        echo 'max_input_time=120'; \
        echo 'date.timezone=UTC'; \
    } > /usr/local/etc/php/conf.d/custom-php.ini

WORKDIR /var/www/html

EXPOSE 9000
CMD ["php-fpm"]
