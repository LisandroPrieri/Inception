NAME        = inception
COMPOSE     = docker compose -f srcs/docker-compose.yml -p $(NAME)
DATA_DIR    = /home/lprieri/data

all: up

up: dirs
	$(COMPOSE) up --build -d

down:
	$(COMPOSE) down

dirs:
	mkdir -p $(DATA_DIR)/mariadb $(DATA_DIR)/wordpress

logs:
	$(COMPOSE) logs -f

clean: down

fclean: down
	docker system prune -af
	sudo rm -rf $(DATA_DIR)

re: fclean all

.PHONY: all up down dirs logs clean fclean re