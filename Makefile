NAME        = inception
COMPOSE     = docker compose -f srcs/docker-compose.yml -p $(NAME)

-include srcs/.env
DATA_DIR   ?= /home/lprieri/data
DOMAIN_NAME ?= lprieri.42.fr

all: up

up: dirs
	$(COMPOSE) up --build -d

down:
	$(COMPOSE) down

dirs:
	mkdir -p $(DATA_DIR)/mariadb $(DATA_DIR)/wordpress

hosts:
	grep -qE "^127\.0\.0\.1[[:space:]]+$(DOMAIN_NAME)$$" /etc/hosts || \
		echo "127.0.0.1 $(DOMAIN_NAME)" | sudo tee -a /etc/hosts

unhosts:
	sudo sed -i "/^127\.0\.0\.1[[:space:]]\+$(DOMAIN_NAME)$$/d" /etc/hosts

logs:
	$(COMPOSE) logs -f

clean: down

fclean:
	$(COMPOSE) down --rmi all --volumes --remove-orphans
	sudo rm -rf $(DATA_DIR)

re: fclean all

.PHONY: all up down dirs hosts unhosts logs clean fclean re