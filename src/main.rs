use actix_web::{post, App, HttpServer, HttpResponse, Responder};
use reqwest::Client;
use serde_json::{from_str, Value};
use url::form_urlencoded;
use std::string::String;
use embryo::{Embryo, EmbryoList};
use std::collections::HashMap;
use std::time::{Instant, Duration};

static SEARCH_URL: &str = "https://archive.org/advancedsearch.php?q=";

#[post("/query")]
async fn query_handler(body: String) -> impl Responder {
    let embryo_list = generate_embryo_list(body).await;
    let response = EmbryoList { embryo_list };
    HttpResponse::Ok().json(response)
}

async fn generate_embryo_list(json_string: String) -> Vec<Embryo> {
    let search: HashMap<String,String> = from_str(&json_string).expect("Can't parse JSON");
    let value = match search.get("value") {
        Some(v) => v,
        None => "",
    };
    let timeout : u64 = match search.get("timeout") {
        Some(t) => t.parse().expect("Can't parse as u64"),
        None => 10,
    };

    let encoded_search: String = form_urlencoded::byte_serialize(value.as_bytes()).collect();
    let search_url = format!("{}{}&output=json", SEARCH_URL, encoded_search);

    println!("{}", search_url);
    let response = Client::new().get(search_url).send().await;

    match response {
        Ok(response) => {
            if let Ok(body) = response.text().await {
                return extract_links_from_results(body, timeout);
            }
        }
        Err(e) => eprintln!("Error fetching search results: {:?}", e),
    }

    Vec::new()
}

fn extract_links_from_results(json_data: String, timeout_secs: u64) -> Vec<Embryo> {
    let mut embryo_list = Vec::new();
    let parsed_json: Value = serde_json::from_str(&json_data).unwrap();
    if let Some(docs) = parsed_json.get("response").and_then(|r| r.get("docs")).and_then(|d| d.as_array()) {
        let start_time = Instant::now();
        let timeout = Duration::from_secs(timeout_secs);
        for doc in docs {
            if start_time.elapsed() >= timeout {
                return embryo_list;
            }
            let mut resume = String::new();
            if let Some(title) = doc.get("title").and_then(|t| t.as_str()) {
                resume = title.to_string();
            }
            if let Some(creator) = doc.get("creator").and_then(|c| c.as_str()) {
                resume = format!("{} - {}", resume, creator);
            }
            if let Some(url) = doc.get("identifier").and_then(|i| i.as_str()) {
                let embryo = Embryo {
                    properties: HashMap::from([("url".to_string(), format!("https://archive.org/details/{}", url).to_string()),("resume".to_string(),resume.to_string())])
                };
                embryo_list.push(embryo);
            }
        }
    }

    embryo_list
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    match em_filter::find_port().await {
        Some(port) => {
            let filter_url = format!("http://localhost:{}/query", port);
            println!("Filter registrer: {}", filter_url);
            em_filter::register_filter(&filter_url).await;
            HttpServer::new(|| App::new().service(query_handler))
                .bind(format!("127.0.0.1:{}", port))?.run().await?;
        },
        None => {
            println!("Can't start");
        },
    }
    Ok(())
}
