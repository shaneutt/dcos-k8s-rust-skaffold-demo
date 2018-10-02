![Kubernetes on DC/OS](https://mesosphere.com/wp-content/uploads/2017/08/kubernetes-dcos-socialtwitter-800x343.png)

**WARNING**: *WORK IN PROGRESS* this demo is under active development and is not ready for general use

# Deploying Rust to Kubernetes on DC/OS with Skaffold

This is a demonstration project for using [Skaffold][0] to pipeline the development of your [Rust][1] web applications to [Kubernetes on DC/OS][2].

If you're not already familiar with DC/OS or Kubernetes see the following:

* https://dcos.io/
* https://kubernetes.io/

## Overview

This demo is divided up into several different steps:

* Step 1 - Kubernetes Ingress
* Step 2 - Base Rust Application
* Step 3 - Deployment
* Step 4 - Database
* Step 5 - REST API
* Step 6 - Conclusions

## Requirements

* [DC/OS][43] 1.11+ cluster with the [Kubernetes framework installation prerequisites][5]
* Kubernetes on DC/OS [1.3.0-1.10.8][12]+ cluster
* [docker][3]
* [kubectl][6]
* [skaffold][0]
* [rust][1] using [rustup][47] (run `rustup default nightly-2018-09-17` to get the specific build for this demo)

## Installing Kubernetes on DC/OS

Installation steps can vary depending on version, see the [DC/OS Kubernetes Documentation][48] for a list of all versions and installation instructions and follow the instructions there until you have access to your cluster with `kubectl`.

For developing this demonstration a cluster with 3 public nodes and 3 private nodes was used. Ensure that there is at least one public, and one private Kubernetes node in your cluster for this demo.

# Step 1 - Kubernetes Ingress

In this guide we'll set up our Kubernetes on DC/OS cluster with [ingress][13] to manage external access to services in the cluster via HTTP.

## NGinx Ingress

For this demo we will use [NGinx][14] as an [ingress][13] resource.

Deploy NGinx ingress:

```yaml
kubectl create -f https://raw.githubusercontent.com/shaneutt/dcos-k8s-rust-skaffold-demo/master/k8s/ingress-nginx.yaml
```

The above will run the NGinx ingress controller as a [DaemonSet][50], deploying a copy of NGinx to each of your public nodes.

For testing going forward, make sure you populate the `PUBLIC_NODE_IP` environment variable with the public IP address of one of your public DC/OS agents running a public Kubernetes node.

# Step 2 - Base Rust App

In this step we're going to get our baseline application built.

We're going to use [rocket.rs][16], a web framework for Rust that makes it simple to write web apps fast.

## App Skeleton

Add the `Cargo.toml` file to add our Rust depedencies:

```toml
cat <<'EOF' > Cargo.toml
[package]
name = "rust-web-demo"
version = "0.1.0"

[dependencies]
diesel = { version = "1.3.3", features = ["postgres"] }
dotenv = "0.13.0"
rocket = "0.3.16"
rocket_codegen = "0.3.16"
serde = "1.0.79"
serde_json = "1.0.27"
serde_derive = "1.0.79"

[dependencies.rocket_contrib]
version = "0.3.16"
default-features = false
features = ["json"]
EOF
```

And then create the `src/main.rs` file with the following contents:

```rust
mkdir -p src/ && cat <<'EOF' > src/main.rs
#![feature(plugin)]
#![plugin(rocket_codegen)]

extern crate rocket;

use rocket::config::{Config, Environment};

#[get("/")]
fn hello() -> String {
    format!("Rocket Webserver!")
}

fn main() {
    let config = Config::build(Environment::Staging)
        .address("0.0.0.0")
        .port(8000)
        .finalize()
        .unwrap();

    rocket::custom(config, true)
        .mount("/", routes![hello])
        .launch();
}
EOF
```

## Dockerfile

In the app directory, create your `Dockerfile` with the following contents:

```dockerfile
cat <<'EOF' > Dockerfile
FROM rustlang/rust@sha256:b62c21120fa9ef720e76f75fcdb53926ddace89feb2e21a1b5944554499aee86

RUN apt-get update

RUN apt-get install musl-tools -y

RUN rustup target add x86_64-unknown-linux-musl

WORKDIR /usr/src/rust-web-demo

COPY Cargo.toml Cargo.toml

RUN mkdir src/

RUN echo "extern crate rocket;\nfn main() {println!(\"if you see this, the build broke\")}" > src/main.rs

RUN RUSTFLAGS=-Clinker=musl-gcc cargo build --release --target=x86_64-unknown-linux-musl

RUN rm -rf src/

RUN rm -f /usr/src/rust-web-demo/target/x86_64-unknown-linux-musl/release/rust-web-demo*

RUN rm -f /usr/src/rust-web-demo/target/x86_64-unknown-linux-musl/release/deps/rust_web_demo*

RUN rm -f /usr/src/rust-web-demo/target/x86_64-unknown-linux-musl/release/rust-web-demo.d

COPY src/* src/

RUN RUSTFLAGS=-Clinker=musl-gcc cargo build --release --target=x86_64-unknown-linux-musl

FROM alpine:latest

RUN apk add --no-cache libpq

WORKDIR /root/

COPY --from=0 /usr/src/rust-web-demo/target/x86_64-unknown-linux-musl/release/rust-web-demo .

CMD ["./rust-web-demo"]
EOF
```

* **NOTE**: the first `FROM` here pulls a nightly version of Rust because [rocket.rs][16] requires nightly to build
* **NOTE**: as of writing this `cargo` [does not yet have a --dependencies-only build option][22] so there are some file removals and rebuilds used to improve Docker caching of builds
* **NOTE**: a [multi-stage docker build][53] is used for this Dockerfile to build a small (<20MB) image for this app (based on [alpine][54])

Also create a `.dockerignore` file to avoid adding files that aren't needed in the docker build:

```
cat <<'EOF' > .dockerignore
dcos/
k8s/
target/
migrations/
skaffold.yaml
skaffold-deployment.yaml
Cargo.lock
LICENSE
EOF
```

Throughout this demo it's assumed you're going to [push][23] your [Docker Image][24] to [Docker Hub][25] so make sure you're logged in with [docker login][26].

## First Test

You can build the Docker image to test the above locally with:

```
docker build -t rust-web-demo .
docker run -p 8000:8000 -d --name rust-web-demo rust-web-demo
```

Access the demo by navigating to http://localhost:8000.

Clean up the container by running:

```
docker kill rust-web-demo
docker rm rust-web-demo
```

# Step 3 - Deployment with Skaffold

In this step we're going to start using [skaffold][0] to continuously ship updates to our code to our Kubernetes on DC/OS cluster.

First we'll simply deploy the app with a basic [Kubernetes Deployment][19], but then we'll update it by adding a [PostgreSQL][20] container and watch Skaffold ship our changes out to Kubernetes.

## Kubernetes Deployment Manifest

We will use a [Kubernetes Deployment][19] to run our application on the cluster via [Skaffold][0].

Create the manifest file `skaffold-deployment.yaml` with the following contents:

```yaml
cat <<'EOF' > skaffold-deployment.yaml
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: rust-web-demo
spec:
  rules:
  - host: DEMO_DOMAIN
    http:
      paths:
      - backend:
          serviceName: rust-web-demo
          servicePort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: rust-web-demo
spec:
  ports:
  - port: 80
    targetPort: 8000
  selector:
    app: rust-web-demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rust-web-demo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: rust-web-demo
  template:
    metadata:
      labels:
        app: rust-web-demo
    spec:
      containers:
      - name: rust-web-demo
        image: docker.io/YOUR_USERNAME/rust-web-demo
        ports:
        - containerPort: 8000
EOF
```

In the above configuration, you'll need to change `DEMO_DOMAIN` to a hostname of your choosing, and `YOUR_USERNAME` to your Docker username. The `DEMO_DOMAIN` can practically be anything as we'll be avoiding DNS and using the [HTTP Host header][27] with `curl` to test our deployments.

`${DEMO_DOMAIN}` will be used as an ENV variable for curl tests throughout the rest of this demo so export that variable now.

## Skaffold

See [installation][28] on the Skaffold Github repo, and install the right version for your system.

If everything is working, you should be able to run the following:

```
$ skaffold version
latest
```

Make sure you are on the latest Skaffold release.

## Skaffold Configuration

To configure Skaffold we're going to create the file `skaffold.yaml` with the following contents:

```yaml
cat <<'EOF' > skaffold.yaml
apiVersion: skaffold/v1alpha2
kind: Config
build:
  artifacts:
  - imageName: docker.io/YOUR_USERNAME/rust-web-demo
    workspace: .
    docker: {}
    bazel: null
  local:
    skipPush: null
  googleCloudBuild: null
  kaniko: null
deploy:
  helm: null
  kubectl:
    manifests:
    - skaffold-deployment.yaml
EOF
```

Change `YOUR_USERNAME` to your Docker username.

## First Deployment

Now that we have the baseline application in place and Skaffold installed and configured we can start deploying.

Dedicate one terminal for running `skaffold` in the foreground and watching its logs.

In the terminal you selected for running `skaffold`, run the following:

```
skaffold dev
```

**NOTE**: You can optionally add `-v debug` option when running `skaffold dev` if you'd like to watch verbose information about what Skaffold is doing, or if you're having problems.

Your image will be built, pushed to Docker hub and deployed to your K8s cluster. The first build may take a long time as several artifacts need to be cached.

You can check on the status of your `rust-web-demo` deployment with `kubectl get deployment rust-web-demo`. Once it's complete, you should soon be able to access your app with:

```
curl -w '\n' -H "Host: ${DEMO_DOMAIN}" ${PUBLIC_NODE_IP}
```

Once everything is working, you'll receive the response `Rocket Webserver!`.

## Automatic Re-Deployment

With Skaffold now running and the first deployment of our services pushed up, any changes we make to code will result in a re-build and re-deployment.

Let's override the `src/main.rs` file so that the previous output "Rocket Webserver!" is replaced with "Skaffold updated me!":

```rust
cat <<'EOF' > src/main.rs
#![feature(plugin)]
#![plugin(rocket_codegen)]

extern crate rocket;

use rocket::config::{Config, Environment};

#[get("/")]
fn hello() -> String {
    format!("Skaffold updated me!")
}

fn main() {
    let config = Config::build(Environment::Staging)
        .address("0.0.0.0")
        .port(8000)
        .finalize().unwrap();

    rocket::custom(config, true)
        .mount("/", routes![hello])
        .launch();
}
EOF
```

After running the above and making the changes to `src/main.rs`, skaffold should build, push and deploy the changes to your cluster.

After the deployment finishes, test it with:

```
curl -H "Host: ${DEMO_DOMAIN}" ${PUBLIC_NODE_IP}
```

You should receive the response `Skaffold updated me!`.

## Deploy PostgreSQL

**WARNING**: The PostgreSQL deployment here is for demonstration purposes only. It's not HA, persistent, nor is it configured securely with SSL.

Now we'll configure a minimal [PostgreSQL][20] Database and add it to our Kubernetes deployment and let Skaffold ship the changes up.

Add a new deployment to `skaffold-deployment.yaml` for the PostgreSQL server:

```yaml
cat <<'EOF' >> skaffold-deployment.yaml
---
apiVersion: v1
kind: Service
metadata:
  name: rust-web-demo-postgres
spec:
  ports:
  - port: 5432
    protocol: TCP
  selector:
    app: rust-web-demo-postgres
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rust-web-demo-postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rust-web-demo-postgres
  template:
    metadata:
      labels:
        app: rust-web-demo-postgres
    spec:
      containers:
      - name: rust-web-demo-postgres
        image: postgres
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: rust-web-demo
        - name: POSTGRES_USER
          value: diesel
        - name: POSTGRES_PASSWORD
          value: changeme
EOF
```

Note that you'll want to update `DEMO_DOMAIN` and `YOUR_USERNAME` in the above file, as with before. Also at the bottom where a service and a deployment for postgres have been added you'll want to change the password value `changeme` to something else.

After you've saved the changes to the file, Skaffold will start updating your deployment, add your database and expose the database interally throughout the k8s cluster.

# Step 4 - Diesel

In this step we'll add [Diesel][30], an ORM for Rust which we'll use to interface with our [PostgreSQL][20] service.

## Database Proxy

For convenience, we'll set up a [port forward][31] to our PostgreSQL instance running in Kubernetes so we can deploy schema updates to it remotely. If you take this demo further, you may want to use something like [Kubernetes init containers][51] to run migrations.

Dedicate a terminal to running the forwarder. Run the following:

```
kubectl port-forward $(kubectl get pods|awk '/^rust-web-demo-postgres.*Running/{print$1}'|head) 5432:5432
```

(Note: you may occasionally need to re-run the above if for some reason the pod you're connected to goes away)

If you have `psql` installed locally, you'll now be able to access the database with the following line:

```
psql -U diesel -h localhost -p 5432 -d rust-web-demo
```

## Diesel Set Up & Configuration

Diesel comes with a [CLI][32] to help us manage our project, and makes it easy to generate, run, and revert database migrations.

### Diesel CLI

Install the [Diesel CLI][32] using `cargo` (you may need to install PostgreSQL development libraries on your system):

```
cargo install diesel_cli --no-default-features --features postgres
```

We'll also build a local `.env` file to instruct the Diesel CLI on how to access our database:

```
echo DATABASE_URL=postgres://diesel:changeme@localhost:5432/rust-web-demo > .env
```

Replacing `changeme` with whatever password you selected for your database.

### Diesel Setup

From here we can have Diesel set up our local environment and deploy a template for migrations:

```
diesel setup
```

The following files will be have been created:

* `migrations/00000000000000_diesel_initial_setup/up.sql`
* `migrations/00000000000000_diesel_initial_setup/down.sql`

These are our first in a series of migrations which we will use to grow and manage the database over time.

The `up.sql` will run to update our schema with changes, and when the `down.sql` it should cleanly remove those changes.

Overwrite `migrations/00000000000000_diesel_initial_setup/up.sql` and add the following contents:

```sql
cat <<'EOF' > migrations/00000000000000_diesel_initial_setup/up.sql
CREATE TABLE employees (
    id         SERIAL PRIMARY KEY,
    fname      VARCHAR NOT NULL,
    lname      VARCHAR NOT NULL,
    age        INTEGER NOT NULL,
    title      VARCHAR NOT NULL
);
EOF
```

Overwrite `migrations/00000000000000_diesel_initial_setup/down.sql` as well with these contents:

```sql
cat <<'EOF' > migrations/00000000000000_diesel_initial_setup/down.sql
DROP TABLE IF EXISTS employees;
DROP SEQUENCE IF EXISTS employees_id_seq;
EOF
```

### Migrations

Now that we have `up.sql` and `down.sql` set up, we can run our first migrations across the kubectl forwarder we set up to the database in Kubernetes:

```
diesel migration run
```

You can test that `down.sql` is working by running:

```
diesel migration redo
```

The above will revert, and then re-apply the migration.

Now if you run `psql -U diesel -h localhost -p 5432 -d rust-web-demo -c '\dt'` you should see the following showing that the migration ran succesfully:

```
                  List of relations
 Schema |            Name            | Type  | Owner
--------+----------------------------+-------+--------
 public | __diesel_schema_migrations | table | diesel
 public | employees                  | table | diesel
(2 rows)
```

## Updating our Rust App with Diesel

At this point diesel_cli is installed, configured, and we've set up and run our first migration.

Our next step is to add code to use the database with Diesel and display database information with Rocket.

### PgConnection

Create a new file `src/postgres.rs` for providing a `PgConnection`, which we'll use to communicate with the database in our code:

```rust
cat <<'EOF' > src/postgres.rs
use diesel::prelude::*;
use diesel::pg::PgConnection;
use dotenv::dotenv;
use std::env;

pub fn connect() -> PgConnection {
    dotenv().ok();

    let database_url = env::var("DATABASE_URL")
        .expect("DATABASE_URL must be set");
    PgConnection::establish(&database_url)
        .expect(&format!("Error connecting to {}", database_url))
}
EOF
```

### Models & Schema

We'll add our `Employee` model from the `employees` table created previously in a new file `src/models.rs`:

```rust
cat <<'EOF' > src/models.rs
#[derive(Queryable)]
pub struct Employee {
    pub id:    i32,
    pub fname: String,
    pub lname: String,
    pub age:   i32,
    pub title: String,
}
EOF
```

And we'll let Diesel generate our `src/schema.rs` file containing a macro automatic code generation and comprehension of our database schema:

```
diesel print-schema > src/schema.rs
```

This file will have the following contents:

```rust
table! {
    employees (id) {
        id -> Int4,
        fname -> Varchar,
        lname -> Varchar,
        age -> Int4,
        title -> Varchar,
    }
}
```

### Bringing it together

With the models, schema and connection code in place we can demonstrate our work.

#### Default Employee

We'll add a single employee manually so that we have some data present to work with by default:

```
psql -U diesel -h localhost -p 5432 -d rust-web-demo -c "INSERT INTO employees (id, fname, lname, age, title) VALUES (1, 'some', 'person', 25, 'Software Engineer');"
psql -U diesel -h localhost -p 5432 -d rust-web-demo -c "SELECT setval('employees_id_seq', 1, true);"
```

You should now be able to run `psql -U diesel -h localhost -p 5432 -d rust-web-demo -c 'SELECT * FROM employees'` and see the employee:

```
 id | fname | lname  | age |       title
----+-------+--------+-----+-------------------
  1 | some  | person |  25 | Software Engineer
(1 row)
```

#### Adding DATABASE_URL to rust-web-demo ENV

We'll add the `DATABASE_URL` to the environment variables for our app container in `skaffold-deployment.yaml` so that the app can use the db.

We'll need to add a [k8s secret][33] to store the sensitive value and use it in the container.

Add the following to the `skaffold-deployment.yaml`:

```yaml
cat <<'EOF' >> skaffold-deployment.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: rust-web-demo-database-url
type: Opaque
data:
  url: cG9zdGdyZXM6Ly9kaWVzZWw6Y2hhbmdlbWVAcnVzdC13ZWItZGVtby1wb3N0Z3Jlczo1NDMyL3J1c3Qtd2ViLWRlbW8=
EOF
```

The value for `key` is base64 encoded `DATABASE_URL` and the `value` is base64 of `postgres://diesel:changeme@rust-web-demo-postgres:5432/rust-web-demo`.

You'll want to update the `value` to contain your own base64 encoded `DATABASE_URL`, which can be easily done with:

```
echo -n 'postgres://diesel:changeme@rust-web-demo-postgres:5432/rust-web-demo' | base64
```

Replacing the `postgres://` parts as needed.

Now to [use the secret as an environment variable][34] you need to update the `rust-web-demo` container to look like this:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rust-web-demo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: rust-web-demo
  template:
    metadata:
      labels:
        app: rust-web-demo
    spec:
      containers:
      - name: rust-web-demo
        image: docker.io/YOUR_USERNAME/rust-web-demo
        ports:
        - containerPort: 8000
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: rust-web-demo-database-url
              key: url
```

Changing `YOUR_USERNAME` to your Docker username as with before.

Note that when you save the file, this is going to trigger a rebuild of the PostgreSQL container via Skaffold so give it a few seconds.

#### Basic Display

We'll update our `src/main.rs` to provide some output that's actually pulled from the database now. Update `src.main.rs` with the following contents:

```rust
cat <<'EOF' > src/main.rs
#![feature(plugin)]
#![plugin(rocket_codegen)]

#[macro_use]
extern crate diesel;
extern crate dotenv;
extern crate rocket;

mod postgres;
mod schema;
mod models;

use rocket::config::{Config, Environment};
use diesel::prelude::*;
use self::models::*;

#[get("/")]
fn hello() -> String {
    use self::schema::employees::dsl::*;

    let db = postgres::connect();
    let results = employees.filter(fname.eq("some"))
        .load::<Employee>(&db)
        .expect("Error loading Employees");

    format!("default employee: {} {}\n", results[0].fname, results[0].lname)
}

fn main() {
    let config = Config::build(Environment::Staging)
        .address("0.0.0.0")
        .port(8000)
        .finalize()
        .unwrap();

    rocket::custom(config, true)
        .mount("/", routes![hello])
        .launch();
}
EOF
```

After you write these changes, Skaffold will ship it off to the cluster and you'll soon be able to check it out with:

```
curl -H "Host: ${DEMO_DOMAIN}" ${PUBLIC_NODE_IP}
```

If everything is working you should receive:

```
Default Employee: some person
```

# REST API with Rocket

In this step we will expand our use of Rocket and Diesel to make a minimal demonstration [REST][35] API.

We will implement GET, PUT, POST, and DELETE methods which will utilize our PostgreSQL database.

You can freeze skaffold temporarily with `CTRL+Z` and resume it with `fg` after all the files here are updated.

## Updating Models

We need to derive several traits for our `Employee` model, including `Serialize` and `Deserialize` for working with the model in JSON, but also `Queryable` and `Insertable` to easily work with the model against the database.

Update the existing `src/models.rs` to contain the following contents:

```rust
cat <<'EOF' > src/models.rs
use schema::employees;

#[derive(Clone, Debug, Serialize, Deserialize, Queryable, Insertable)]
#[table_name = "employees"]
pub struct Employee {
    pub id:    i32,
    pub fname: String,
    pub lname: String,
    pub age:   i32,
    pub title: String,
}

#[derive(Serialize, Deserialize)]
pub struct EmployeeList {
    pub results: Vec<Employee>,
}
EOF
```

Note that we also created `EmployeeList`, which will be used for producing multiple `Employee` results in API calls.

## Adding Errors

We're going to add a simple JSON serializable struct for handling ApiErrors, create the new file `src/errors.rs` with the following contents:

```rust
cat <<'EOF' > src/errors.rs
#[derive(Clone, Serialize, Deserialize)]
pub struct ApiError {
    pub message: String,
}
EOF
```

## Adding Forms

We'll need a serializable [Rocket Form][37] to make it simple to accept `Employee` related parameters in HTTP requests for GET, PUT, POST, and DELETE.

Add the new file `src/forms.rs` with the following contents:

```rust
cat <<'EOF' > src/forms.rs
use schema::employees;

#[derive(Clone, Debug, Serialize, Deserialize, FromForm, Insertable, AsChangeset)]
#[table_name = "employees"]
pub struct EmployeeForm {
    pub id:    Option<i32>,
    pub fname: Option<String>,
    pub lname: Option<String>,
    pub age:   Option<i32>,
    pub title: Option<String>,
}
EOF
```

We've also implemented Insertable for this Form, as that will make it simple to use in database INSERTs.

## Adding the API HTTP Methods: GET, PUT, POST & DELETE

Now we can add our actual HTTP methods for the API so that we can GET, PUT, POST, and DELETE our employee data.

Add the new file `src/api.rs` with the following contents:

```rust
cat <<'EOF' > src/api.rs
use diesel::{delete, insert_into, update};
use diesel::prelude::*;

use rocket;
use rocket::{Catcher, Route, Request};
use rocket::response::status::{BadRequest, Created, NoContent};
use rocket_contrib::Json;

use errors::ApiError;
use forms::EmployeeForm;
use models::{Employee, EmployeeList};
use postgres::connect as dbc;

// -----------------------------------------------------------------------------
// HTTP Errors
// -----------------------------------------------------------------------------

#[catch(404)]
fn not_found(_: &Request) -> Json<ApiError> {
    Json(ApiError{
        message: "not found".to_string(),
    })
}

// -----------------------------------------------------------------------------
// HTTP GET, PUT, POST & DELETE
// -----------------------------------------------------------------------------

#[get("/employees", format = "application/json")]
fn employee_list() -> Json<EmployeeList> {
    use schema::employees::dsl::*;

    let db = dbc();
    let results = employees.load::<Employee>(&db)
        .expect("Error loading Employees");

    Json(EmployeeList {
        results: results.to_vec(),
    })
}

#[get("/employees/<employee_id>", format = "application/json")]
fn employee_get(employee_id: i32) -> Option<Json<Employee>> {
    use schema::employees::dsl::*;

    let db = dbc();
    match employees.find(employee_id).first::<Employee>(&db) {
        Ok(employee) => Some(Json(employee)),
        Err(_) => None,
    }
}

#[put("/employees", format = "application/json", data = "<json_employee>")]
fn employee_put(json_employee: Json<EmployeeForm>) -> Result<Created<()>, BadRequest<String>> {
    use schema::employees::dsl::*;

    let mut new_employee = json_employee.into_inner();
    new_employee.id = None;
    let insert = insert_into(employees)
        .values(&new_employee);

    let db = dbc();
    match insert.execute(&db) {
        Ok(_) => {
            Ok(Created("/employees".to_string(), Some(())))
        },
        Err(err) => {
            let err = json!({"error": err.to_string()});
            Err(BadRequest(Some(err.to_string())))
        },
    }
}

#[post("/employees/<employee_id>", format = "application/json", data = "<json_employee>")]
fn employee_update(employee_id: i32, json_employee: Json<EmployeeForm>) -> Result<NoContent, BadRequest<String>> {
    use schema::employees::dsl::*;

    let employee = json_employee.into_inner();
    let update = update(employees.filter(id.eq(employee_id)))
        .set(&employee);

    let db = dbc();
    match update.execute(&db) {
        Ok(_) => Ok(NoContent),
        Err(err) => {
            let err = json!({"error": err.to_string()});
            Err(BadRequest(Some(err.to_string())))
        },
    }
}

#[delete("/employees/<employee_id>", format = "application/json")]
fn employee_delete(employee_id: i32) -> Option<NoContent> {
    use schema::employees::dsl::*;

    let db = dbc();
    let deleted = delete(employees.find(employee_id)).execute(&db)
        .expect("Error deleting Employee");

    if deleted >= 1 {
        Some(NoContent)
    } else {
        None
    }
}

// -----------------------------------------------------------------------------
// HTTP Routes
// -----------------------------------------------------------------------------

pub fn gen_routes() -> Vec<Route> {
    routes![employee_list, employee_get, employee_put, employee_update, employee_delete]
}

pub fn gen_errors() -> Vec<Catcher> {
    catchers![not_found]
}
EOF
```

Note that there are some inefficiencies with our methods, such as creating a database connection for each method call. This was left simple for demonstration purposes, but we will revisit this and talk about some potential improvements (such as using Rocket's [Managed State][38] with [Diesel R2D2 connection pooling][39]) at the end.

# Bringing it all together

Now that we've added the API and several necessary pieces, we'll glue it all together in the main by updating `src/main.rs` to have the following contents:

```rust
cat <<'EOF' > src/main.rs
#![feature(plugin)]
#![feature(custom_derive)]
#![plugin(rocket_codegen)]

#[macro_use] extern crate diesel;
#[macro_use] extern crate serde_derive;
#[macro_use] extern crate serde_json;
extern crate rocket_contrib;
extern crate rocket;
extern crate dotenv;

mod api;
mod errors;
mod forms;
mod models;
mod postgres;
mod schema;

use rocket::config::{Config, Environment};

use api::{gen_routes, gen_errors};

fn main() {
    let config = Config::build(Environment::Staging)
        .address("0.0.0.0")
        .port(8000)
        .finalize()
        .unwrap();

    rocket::custom(config, true)
        .mount("/", gen_routes())
        .catch(gen_errors())
        .launch();
}
EOF
```

Once you've saved the changes to this file and all the other files added and modified above you can run `fg` to let skaffold deploy the new changes (if you froze it previously).

## Using the API

### GET

Once Skaffold has finished its work and your app is fully deployed, you should be able to GET the initial `Employee` from our migrations:

```
curl -s -w '\n%{http_code}\n' -H "Host: ${DEMO_DOMAIN}" http://${PUBLIC_NODE_IP}/employees/1
```

You should receive a 200 HTTP Ok and the JSON of the `Employee`.

You should also be able to see the initial `Employee` in an `EmployeeList`:

```
curl -s -w '\n%{http_code}\n' -H "Host: ${DEMO_DOMAIN}" http://${PUBLIC_NODE_IP}/employees
```

You should receive a 200 HTTP Ok and the JSON of the `EmployeeList`.

### PUT

You can add a new `Employee`:

```
curl -s -w '\n%{http_code}\n' -X PUT \
    -H "Host: ${DEMO_DOMAIN}" \
    -H 'Content-Type: application/json' \
    -d '{"fname":"new", "lname":"person", "age": 27, "title":"Devops Engineer"}' \
    http://${PUBLIC_NODE_IP}/employees
```

You should receive a 201 Created.

### POST

You can update some information on that `Employee` with a POST:

```
curl -s -w '\n%{http_code}\n' -X POST \
    -H "Host: ${DEMO_DOMAIN}" \
    -H 'Content-Type: application/json' \
    -d '{"age": 29}' \
    http://${PUBLIC_NODE_IP}/employees/<employee_id>
```

In the above `<employee_id>` will be whatever you received for the `id` in the PUT operation above (probably it will be 2 at this point unless you've done further experimentation).

Now you can get a new `EmployeeList` and see the previous entries plus your newly created (and updated) entry:

```
curl -s -w '\n%{http_code}\n' -H "Host: ${DEMO_DOMAIN}" http://${PUBLIC_NODE_IP}/employees
```

### DELETE

When you're done you can delete the created employee(s):

```
curl -s -w '\n%{http_code}\n' -X DELETE \
    -H 'Content-Type: application/json' \
    -H "Host: ${DEMO_DOMAIN}" \
    http://${PUBLIC_NODE_IP}/employees/<employee_id>
```

# Cleanup & Conclusion

If you would like to cleanup the resources deployed in this demo you can use `CTRL+C` to stop skaffold, which will cause it to clean up it's resources, and then you can remove the NGinx ingress components with:

```
kubectl delete -f https://raw.githubusercontent.com/shaneutt/dcos-k8s-rust-skaffold-demo/master/k8s/ingress-nginx.yaml
```

In this demo we deployed Kubernetes on DC/OS, set up NGinx as Ingress, built and deployed an app, expanded on our app using Diesel and Rocket and watched Skaffold build and ship the results in the background while we were making changes. If you like building web applications with Diesel and Rocket, I recommend following up by reading the [Diesel Documentation][40] and the [Rocket Documentation][41] to continue learning.

Throughout our demonstration we did something things simply to avoid overcomplicating the code examples, if you decide you'd like to continue building off of the examples here for your own application you may want to look into using [Diesel Connection Pooling][39] to avoid separate connections for each request, and storing the connection pool via [Rocket Managed State][38]. You'll want to investigate some HA set ups for PostgreSQL, potentially something like [PostgreSQL XL][52]. You'll also want to develop some pagination layer on top of the GET methods in the examples, and implement further search functionality.

It's encouraged to read more on [Skaffold][0] to get to better know more of the options and features avaiable.

For more information about Kubernetes on DC/OS, see [Mesosphere's Kubernetes service page][42].

If you'd like help with DC/OS see the [DC/OS Documentation][43] or [Contact Mesosphere][44].

[0]:https://github.com/GoogleCloudPlatform/skaffold
[1]:https://www.rust-lang.org
[2]:https://docs.mesosphere.com/services/kubernetes/
[3]:https://docs.docker.com/install/
[4]:https://www.rust-lang.org/install.html
[5]:https://docs.mesosphere.com/services/kubernetes/1.3.0-1.10.8/install/
[6]:https://kubernetes.io/docs/tasks/tools/install-kubectl/
[8]:https://docs.mesosphere.com/services/kubernetes/1.3.0-1.10.8/quick-start/
[9]:https://www.gnu.org/software/make/
[11]:https://dcos.io/docs/latest/cli/
[12]:https://docs.mesosphere.com/services/kubernetes/1.3.0-1.10.8/
[13]:https://kubernetes.io/docs/concepts/services-networking/ingress/
[14]:https://nginx.org
[15]:https://kubernetes.io/docs/admin/service-accounts-admin/
[16]:https://rocket.rs
[17]:https://doc.rust-lang.org/cargo/reference/manifest.html
[18]:https://github.com/GoogleCloudPlatform/skaffold
[19]:https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
[20]:https://www.postgresql.org/
[22]:https://github.com/rust-lang/cargo/issues/2644
[23]:https://docs.docker.com/engine/reference/commandline/push/
[24]:https://docs.docker.com/engine/reference/commandline/images/
[25]:https://hub.docker.com/
[26]:https://docs.docker.com/engine/reference/commandline/login/
[27]:https://developer.mozilla.org/docs/Web/HTTP/Headers/Host
[28]:https://github.com/GoogleCloudPlatform/skaffold#installation
[29]:https://docs.docker.com/engine/reference/commandline/login/
[30]:https://diesel.rs
[31]:https://kubernetes.io/docs/tasks/access-application-cluster/port-forward-access-application-cluster/
[32]:https://github.com/diesel-rs/diesel/tree/master/diesel_cli
[33]:https://kubernetes.io/docs/concepts/configuration/secret/
[34]:https://kubernetes.io/docs/concepts/configuration/secret/#using-secrets-as-environment-variables
[35]:https://en.wikipedia.org/wiki/Representational_state_transfer
[36]:https://github.com/serde-rs/serde
[37]:https://rocket.rs/guide/requests/#forms
[38]:https://rocket.rs/guide/state/#managed-state
[39]:https://github.com/diesel-rs/r2d2-diesel
[40]:https://docs.diesel.rs/diesel/index.html
[41]:https://api.rocket.rs/rocket/
[42]:https://docs.mesosphere.com/services/kubernetes/
[43]:https://docs.mesosphere.com/
[44]:https://mesosphere.com/contact/
[45]:https://kubernetes.io/docs/concepts/workloads/pods/init-containers/
[46]:https://rocket.rs/guide/getting-started/#installing-rust
[47]:https://rustup.rs
[48]:https://docs.mesosphere.com/services/kubernetes/
[49]:https://doc.rust-lang.org/book/second-edition/ch14-01-release-profiles.html
[50]:https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
[51]:https://kubernetes.io/docs/concepts/workloads/pods/init-containers/
[52]:https://www.postgres-xl.org/
[53]:https://docs.docker.com/develop/develop-images/multistage-build/
[54]:https://www.alpinelinux.org/
