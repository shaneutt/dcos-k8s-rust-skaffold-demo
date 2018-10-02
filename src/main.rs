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
