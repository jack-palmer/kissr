authorizationHeader <- function() {
  apiToken <- Sys.getenv("KM_API_TOKEN")
  if (is.null(apiToken) || apiToken == "") stop("Please set your KissMetrics api token with Sys.setenv('KM_API_TOKEN')")

  c("Authorization" = paste("Bearer", apiToken))
}

jsonHeader <- function() {
  c("Content-Type" = "application/json")
}

as.list.Interval <- function(interval) {
  list( start_date = lubridate::int_start(interval),
        end_date = lubridate::int_end(interval))
}

# convert dates to timestamps
as.timestamp <- function(date) {
  strftime(date, format = "%Y-%m-%dT%H:%M:%S%z")
}

# replace any substrings matching the placeholder regex patter with value
# @example
# string <- "{'foo':'{{bar}}'}"
# json <- segmentTemplate
# json <- replacePlaceholder(json, "\\{\\{type\\}\\}", segment$type)
replacePlaceholder <- function(string, placeholder, value) {
  stringr::str_replace_all(string,
                           stringr::regex(placeholder, multiline = TRUE),
                           value)
}


# Format an httr::url to a simple string
format.url <- function(url) {
  httr::build_url(url)
}

makeKMDateRange <- function(interval) {
  list(
    dateRangeId = "custom",
    startDate = as.timestamp(lubridate::int_start(interval)),
    endDate = as.timestamp(lubridate::int_end(interval))
  )
}

# Read data from a URL - will retry MAX_RETRY_COUNT times if response code isn't
# a 200
readUrl <- function(url, cacheObject) {
  headers <- c(authorizationHeader(), jsonHeader())
  requestKey = c(url, headers)
  response <- readCache(cacheObject, requestKey)

  if (is.null(response)) {
    maxTries <- ifelse(is.na(Sys.getenv("MAX_RETRY_COUNT")),
                       Sys.getenv("MAX_RETRY_COUNT"),
                       10)
    tries <- 0
    repeat {
      response <- httr::GET(url, httr::add_headers(headers))
      tries <- tries + 1
      if(!httr::http_error(response)) {
        writeCache(cacheObject, requestKey, response)
        break
      }
      else if (tries >= maxTries) {
        stop("Reached maximum retry count for url:", url, "\n",
             "Server Response:", httr::message_for_status(response))
      }
      Sys.sleep(2)
    }
  }

  response
}

# generate a cache key from an object
as.cacheKey <- function(object) {
  if (!is.character(object)) object <- sapply(object, format)

  paste0(object, collapse=":")
}

# return whatever is stored by cache
readCache <- function (object, key) {
  key <- as.cacheKey(key)
  object$cache[[key]]
}

# return old value
writeCache <- function (object, key, value) {
  key <- as.cacheKey(key)

  old = object$cache[[key]]
  object$cache[[key]] = value

  invisible(old)
}

# Build a set of urls matching all the offsets from the url template
buildPaginationUrls <- function(urlTemplate, offsets) {
  matches <- "\\{\\{OFFSET\\}\\}"
  stringr::str_replace_all(urlTemplate,
                           matches,
                           format(offsets,
                                  scientific=FALSE,
                                  trim=TRUE))
}

# Pull out Kissmetrics results as matrix
GetDataFromReport <- function(fetchedResults) {
  # Check if "identity" and "columns" field exist in results
  # If they do, convert results into matrix
  resultsColumnNames <- names(fetchedResults$data)
  if(sum(resultsColumnNames %in% c("identity","columns")) == 2){
    resultsColumns <- matrix(unlist(fetchedResults$data$columns),
                             ncol = length(fetchedResults$data$columns[[1]]),
                             byrow = TRUE)
    reportMatrix <- cbind(fetchedResults$data$identity,
                          resultsColumns)
  } else {
    reportMatrix <- fetchedResults$data[,-1]
  }
  return(reportMatrix)
}

# load data from a page
loadPage <- function (url, object) {
  # Provide a status update
  cat(stringr::str_extract(url,"offset=\\d+"), "|")
  results <- tryCatch( {
    response <- readUrl(url, object)
    results <- jsonlite::fromJSON(httr::content(response, "text"))
    GetDataFromReport(results)
  },
  error = function(e) { e }
  )
  results
}

# Load all data from a series of pages
loadPages <- function (object, url) {
  response <- readUrl(url, object)
  pages <- jsonlite::fromJSON(httr::content(response, "text"))

  totalItems <- pages$pagination$total
  itemsPerPage <- 1000

  print(paste("Loading", ceiling(totalItems/itemsPerPage), "pages:",
              format(itemsPerPage, scientific=FALSE), "results per page."))

  if(totalItems > 0) {
    # Rip out any existing query params
    urlTemplate <- stringr::str_c(stringr::str_split(url, "\\?", 2)[[1]][1],
                                  "?limit=", format(itemsPerPage, scientific=FALSE), "\u0026offset={{OFFSET}}")


    urls <- buildPaginationUrls(urlTemplate = urlTemplate,
                                offsets = seq(from=0,
                                              to=totalItems - 1,
                                              by=itemsPerPage))
    result <- do.call(rbind, lapply(urls, loadPage, object=object))
  } else if (is.null(object$columnNames)) {
    result <- data.frame(product_id=c(), account_id=c(), report_type=c(), name=c(), created_at=c(), links=c())
  } else {
    result <- setNames(data.frame(matrix(ncol=length(object$columnNames), nrow=0)),
                       object$columnNames)
  }
  return(result)
}

reportCalculationClasses <- function(report) {
  calculationTypes <- c("character", sapply(report$calculations, function(calculation) calculation$type))
  ifelse(stringr::str_detect(calculationTypes, "_date_"), "timestamp", "character")
}
