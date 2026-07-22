# Learner notes

Personal notes on the concepts behind this project — the "why it works this way," written to be understood and defended, not to satisfy the subject. Grows as the project does.

---

## How a `docker-compose.yml` actually works

Compose is **declarative**: you describe the desired end state, Compose reads the whole file, builds a model of what you declared, and reconciles reality to match. This is the opposite of a Makefile, which is **imperative** — a list of rules ("to build X, run these commands"). In compose you don't write actions; you write the picture of what should exist.

The key to reading the file is that there are **two kinds of names**, and telling them apart is the whole game.

### 1. Spec keywords — fixed vocabulary

These are defined by the Compose specification. You cannot rename them; Compose only recognizes this exact set. Typo one (`volumez:`) and Compose errors — proof it's a closed vocabulary, not free-form.

The four top-level keywords:

```
services:    # the containers
networks:    # the virtual switches they join
volumes:     # the persistent storage
secrets:     # files with sensitive content, mounted into containers
```

Inside a service, more keywords, each with a meaning and an expected value shape:

```
services:
  mariadb:         # <- NOT a keyword, my name (see below)
    build:         # keyword: path to a Dockerfile dir
    image:         # keyword: name to give the built image
    env_file:      # keyword: file of environment variables
    volumes:       # keyword: which volumes to mount, and where
    networks:      # keyword: which networks to join
    depends_on:    # keyword: start order
    restart:       # keyword: restart policy
```

### 2. My identifiers — names I coin, then reference by matching

`mariadb`, `inception`, `db_data`, `wp_data` are labels **I** chose. What makes them work is **name-matching across the file**: coin a name in one place (the *declaration*), refer to it by identical spelling elsewhere (the *reference*). Compose links them by matching the strings.

```
services:
  wordpress:
    volumes:
      - wp_data:/var/www/html   # reference: "use the volume called wp_data"
                                #            mounted at /var/www/html
volumes:
  wp_data:                      # declaration: here is what wp_data is
    driver: local
```

Same pattern everywhere identifiers connect parts:
- a service's `networks:` list references a network declared under top-level `networks:`
- a service's `secrets:` list references a secret declared under top-level `secrets:`

It's exactly like declaring a variable once and using it in several places.

### The mental model

- **Keywords are the grammar** — fixed, come from the spec.
- **My identifiers are the nouns** — I invent them.
- **Matching identical names is how the parts connect** — declaration in one place, references elsewhere.

### The `<name>:<path>` shorthand in mounts

In `volumes:` and (later) `secrets:` lists, the entry is `identifier:location-inside-container`. `wp_data:/var/www/html` means "mount the volume I called `wp_data` at the path `/var/www/html` inside this container." Left of the colon is one of my identifiers; right of the colon is a path in the container's filesystem.
