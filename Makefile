NAME        = inception
COMPOSE     = docker compose -f srcs/docker-compose.yml -p $(NAME)

-include srcs/.env
DATA_DIR   ?= /home/lprieri/data

all: up

up: dirs
	$(COMPOSE) up --build -d

down:
	$(COMPOSE) down

dirs:
	mkdir -p $(DATA_DIR)/mariadb $(DATA_DIR)/wordpress

hosts:
	echo "127.0.0.1 lprieri.42.fr" | sudo tee -a /etc/hosts

logs:
	$(COMPOSE) logs -f

clean: down

fclean:
	$(COMPOSE) down --rmi all --volumes --remove-orphans
	sudo rm -rf $(DATA_DIR)

re: fclean all

.PHONY: all up down dirs hosts logs clean fclean re