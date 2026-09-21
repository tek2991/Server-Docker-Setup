-- =============================================================
-- Initial Database and User Setup for 4 Internal Laravel Apps
-- Executed automatically on initial MariaDB container startup
-- =============================================================

-- Dwelly Application
CREATE DATABASE IF NOT EXISTS dwelly CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'dwelly'@'%' IDENTIFIED BY 'change_me_dwelly';
GRANT ALL PRIVILEGES ON dwelly.* TO 'dwelly'@'%';

-- Site B Application
CREATE DATABASE IF NOT EXISTS site_b CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'site_b'@'%' IDENTIFIED BY 'change_me_site_b';
GRANT ALL PRIVILEGES ON site_b.* TO 'site_b'@'%';

-- Site C Application
CREATE DATABASE IF NOT EXISTS site_c CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'site_c'@'%' IDENTIFIED BY 'change_me_site_c';
GRANT ALL PRIVILEGES ON site_c.* TO 'site_c'@'%';

-- Site D Application
CREATE DATABASE IF NOT EXISTS site_d CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'site_d'@'%' IDENTIFIED BY 'change_me_site_d';
GRANT ALL PRIVILEGES ON site_d.* TO 'site_d'@'%';

FLUSH PRIVILEGES;
