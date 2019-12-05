#!/bin/bash

work_dir="$(pwd)"
tools_dir="$(cd "$(dirname "$0")" && pwd)"

tmp="/tmp/$$"

higienizar_parametros_secretos() {
  if [ "$CONSUMER_KEY" = '' ]
  then
    cat
    return 0
  fi
  $esed -e "s/$CONSUMER_KEY/<***consumer-key***>/g" \
        -e "s/$CONSUMER_SECRET/(***consumer-secret***>/g" \
        -e "s/$ACCESS_TOKEN/<***access-token***>/g" \
        -e "s/$ACCESS_TOKEN_SECRET/<***access-token-secret***>/g"
}

existe_comando() {
  type "$1" > /dev/null 2>&1
}

carregar_keys() {
  if [ "$CONSUMER_KEY" = '' -a \
       -f "$work_dir/tweet.client.key" -a \
       "$work_dir" != "$tools_dir" ]
  then
    source "$work_dir/tweet.client.key"
  fi

  if [ "$CONSUMER_KEY" = '' -a \
       -f ~/.tweet.client.key ]
  then
    source ~/.tweet.client.key
  fi

  if [ "$CONSUMER_KEY" = '' -a \
       -f "$tools_dir/tweet.client.key" ]
  then
    source "$tools_dir/tweet.client.key"
  fi

  export MY_SCREEN_NAME
  export MY_LANGUAGE
  export CONSUMER_KEY
  export CONSUMER_SECRET
  export ACCESS_TOKEN
  export ACCESS_TOKEN_SECRET
}

case $(uname) in
  Darwin|*BSD|CYGWIN*)
    esed="sed -E"
    ;;
  *)
    esed="sed -r"
    ;;
esac


garantir_disponivel() {
  local fatal_error=0

  carregar_keys

  if [ "$MY_SCREEN_NAME" = '' ]
  then
    echo 'FATAL ERROR: Você precisa especificar seu screen name por meio de uma variável de ambiente "MY_SCREEN_NAME".' 1>&2
    fatal_error=1
  fi

  if [ "$MY_LANGUAGE" = '' ]
  then
    echo 'FATAL ERROR: Você precisa especificar seu idioma (como "pt") por meio de uma variável de ambiente "MY_LANGUAGE".' 1>&2
    fatal_error=1
  fi

  if [ "$CONSUMER_KEY" = '' ]
  then
    echo 'FATAL ERROR: Você precisa especificar uma consumer key por meio de uma variável de ambiente "CONSUMER_KEY".' 1>&2
    fatal_error=1
  fi

  if [ "$CONSUMER_SECRET" = '' ]
  then
    echo 'FATAL ERROR: Você precisa especificar uma consumer secret por meio de uma variável de ambiente "CONSUMER_SECRET".' 1>&2
    fatal_error=1
  fi

  if [ "$ACCESS_TOKEN" = '' ]
  then
    echo 'FATAL ERROR: Você precisa especificar um access token por meio de uma variável de ambiente "ACCESS_TOKEN".' 1>&2
    fatal_error=1
  fi

  if [ "$ACCESS_TOKEN_SECRET" = '' ]
  then
    echo 'FATAL ERROR: Você precisa especificar access token secret por meio de uma variável de ambiente "ACCESS_TOKEN_SECRET".' 1>&2
    fatal_error=1
  fi

  if ! existe_comando nkf
  then
    echo 'FATAL ERROR: Um comando obrigatório "nkf" está ausente.' 1>&2
    fatal_error=1
  fi

  if ! existe_comando curl
  then
    echo 'FATAL ERROR: Um comando obrigatório "curl" está ausente.' 1>&2
    fatal_error=1
  fi

  if ! existe_comando openssl
  then
    echo 'FATAL ERROR: Um comando obrigatório "openssl" está ausente.' 1>&2
    fatal_error=1
  fi

  if ! existe_comando jq
  then
    echo 'FATAL ERROR: Um comando obrigatório "jq" está ausente.' 1>&2
    fatal_error=1
  fi

  [ $fatal_error = 1 ] && exit 1
}


#================================================================

corpo() {
  local target="$1"
  if [ "$target" != '' ]
  then
    local id="$(echo "$target" | extract_tweet_id)"
    fetch "$id" | corpo
  else
    jq -r .text | unicode_unescape
  fi
}

corpo_de_postagem() {
  if [ "$*" = '' ]; then
    cat | $esed -e 's/$/\\n/' | paste -s -d '\0' -
  else
    echo -n -e "$*" | $esed -e 's/$/\\n/' | paste -s -d '\0' -
  fi
}

post() {
  garantir_disponivel

  local params="$(cat << FIN
status $(corpo_de_postagem $*)
$location_params
$media_params
FIN
  )"
  local result="$(echo "$params" |
                    ligar_api POST https://api.twitter.com/1.1/statuses/update.json)"

  date
  echo "$result"
}

#================================================================
# utilitários para operar texto

codificar_url() {
  # processo por linha, porque o nkf -MQ divide automaticamente
  # a string de saída com 72 caracteres por linha.
  while read -r line
  do
    echo -e "$line" |
      while read -r part
      do
        echo "$part" |
          # converter para MIME entre aspas imprimível
          # W8 => a codificação de entrada é UTF-8
          # MQ => cotado imprimível
          nkf -W8MQ |
          sed 's/=$//' |
          tr '=' '%' |
          # reunir links quebrados para uma linha
          paste -s -d '\0' - |
          sed -e 's/%7E/~/g' \
              -e 's/%5F/_/g' \
              -e 's/%2D/-/g' \
              -e 's/%2E/./g'
      done |
        sed 's/$/%0A/g' |
        paste -s -d '\0' - |
        sed 's/%0A$//'
  done
}

para_lista_codificada() {
  local delimiter="$1"
  [ "$delimiter" = '' ] && delimiter='\&'
  local transformed="$( \
    # sort params by their name
    sort -k 1 -t ' ' |
    # remove blank lines
    grep -v '^\s*$' |
    # "name a b c" => "name%20a%20b%20c"
    codificar_url |
    # "name%20a%20b%20c" => "name=a%20b%20c"
    sed 's/%20/=/' |
    # connect lines with the delimiter
    paste -s -d "$delimiter" - |
    # remove last line break
    tr -d '\n')"
  echo "$transformed"
}

URL_REDIRECTORS_MATCHER="^https?://($(echo "$URL_REDIRECTORS" | $esed 's/\./\\./g' | paste -s -d '|' - | $esed 's/^ *| *$//g'))/"

resolver_url_original() {
  while read -r url
  do
    if echo "$url" | egrep -i "$URL_REDIRECTORS_MATCHER" 2>&1 >/dev/null
    then
      curl --silent --head "$url" | egrep -i "^Location:" | $esed "s/^[^:]+: *//"
    else
      echo $url
    fi
  done
}

resolver_todas_urls() {
  input="$(cat)"
  url_resolvers="$(echo "$input" |
    egrep -o -i 'https?://[a-z0-9/\.]+' |
    sort |
    uniq |
    while read url
    do
      resolved="$(./tweetbot.sh/tweet.sh/tweet.sh resolve "$url" |
                    $esed -e 's/([$&])/\\\1/g' |
                    tr -d '\r\n')"
      if [ "$url" != "$resolved" ]
      then
        echo -n " -e s;$url;$resolved;g"
      fi
    done)"
  if [ "$url_resolvers" != '' ]
  then
    echo -n "$input" | $esed $url_resolvers
  else
    echo -n "$input"
  fi
}


#================================================================
# utilitários para gerar solicitações de API com autenticação OAuth

ligar_api() {
  local method=$1
  local url=$2
  local file=$3
  local data_type=$4

  local params=''
  local raw_params=''
  local content_type_header=''
  if [ ! -t 0 ]
  then
    raw_params="$(cat)"
    if [ "$data_type" = 'json' ]
    then
      content_type_header="--header 'content-type: application/json'"
      # no params for authentication!
    else
      params="$raw_params"
    fi
  fi

  local oauth="$(echo "$params" | gerar_cabecalho_oauth "$method" "$url")"
  local headers="Authorization: OAuth $oauth"
  params="$(echo "$params" | para_lista_codificada)"


  local file_params=''
  if [ "$file" != '' ]
  then
    local file_param_name="$(echo "$file" | $esed 's/=.+$//')"
    local file_path="$(echo "$file" | $esed 's/^[^=]+=//')"
    file_params="--form $file_param_name=@$file_path"
  fi

  local debug_params=''
  if [ "$DEBUG" != '' ]
  then
    debug_params="--verbose"
  fi

  local curl_params
  if [ "$method" = 'POST' ]
  then
    local main_params=''
    if [ "$file_params" = '' ]
    then
      if [ "$data_type" = 'json' ]
      then
        main_params="--data \"$(echo "$raw_params" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')\""
      else
        # --data parameter requries any input even if it is blank.
        if [ "$params" = '' ]
        then
          params='""'
        fi
        main_params="--data \"$params\""
      fi
    elif [ "$params" != '""' -a "$params" != '' ]
    then
      # on the other hand, --form parameter doesn't accept blank input.
      main_params="--form \"$params\""
    fi
    curl_params="--header \"$headers\" \
         $content_type_header \
         --silent \
         $main_params \
         $file_params \
         $debug_params \
         $url"
  else
    curl_params="--get \
         --header \"$headers\" \
         --data \"$params\" \
         --silent \
         --http1.1 \
         $debug_params \
         $url"
  fi
  curl_params="$(echo "$curl_params" | tr -d '\n' | $esed 's/  +/ /g')"
  if [ "$debug_params" = '' ]
  then
    eval "curl $curl_params"
  else
    # to apply higienizar_parametros_secretos only for stderr, swap stderr and stdout temporally.
    (eval "curl $curl_params" 3>&2 2>&1 1>&3 | higienizar_parametros_secretos) 3>&2 2>&1 1>&3
  fi
}

gerar_cabecalho_oauth() {
  local method=$1
  local url=$2

  local parametros_comuns="$(parametros_comuns)"

  local signature=$(cat - <(echo "$parametros_comuns") | gerar_assinatura "$method" "$url")
  local header=$(cat <(echo "$parametros_comuns") <(echo "oauth_signature $signature") |
    para_lista_codificada ',' |
    tr -d '\n')

  echo -n "$header"
}

gerar_assinatura() {
  local method=$1
  local url=$2

  local signature_key="${CONSUMER_SECRET}&${ACCESS_TOKEN_SECRET}"

  local encoded_url="$(echo "$url" | codificar_url)"
  local signature_source="${method}&${encoded_url}&$( \
    para_lista_codificada |
    codificar_url |
    # Remove last extra line-break
    tr -d '\n')"

  # generate signature
  local signature=$(echo -n "$signature_source" |
    openssl sha1 -hmac $signature_key -binary |
    openssl base64 |
    tr -d '\n')

  echo -n "$signature"
}

parametros_comuns() {
  cat << FIN
oauth_consumer_key $CONSUMER_KEY
oauth_nonce $(date +%s%N)
oauth_signature_method HMAC-SHA1
oauth_timestamp $(date +%s)
oauth_token $ACCESS_TOKEN
oauth_version 1.0
FIN
}

#================================================================
while true
do
  carga=$(echo "Carga média da CPU: "$(cat /proc/loadavg))
  memoria=$(echo "Memória usada: "$(free -m -t | grep Mem | tr -s '[:space:]''' | cut -f3 -d" ")"G")
  disco=$(echo "Espaço livre em disco: "$(df -h | grep sda2 | tr -s '[:space:]''' | cut -f4 -d" "))

  tweet="$carga\n$memoria\n$disco"

  post $tweet
  sleep $1
done
