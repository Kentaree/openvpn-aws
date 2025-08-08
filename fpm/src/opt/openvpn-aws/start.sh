#!/bin/bash
AWSVPNCLIENT_CONF_DIR=~/.config/AWSVPNClient/OpenVpnConfigs
RUN_DIR=/var/run/user/${UID}/openvpn-aws

# Parse command line arguments
CONNECTION_NAME=""
if [ "$1" != "" ]; then
  CONNECTION_NAME="$1"
fi

# FUNCTIONS
get_conf() {
  # If connection name provided via command line, use it directly
  if [ "$CONNECTION_NAME" != "" ]; then
    VPNCONF="${CONNECTION_NAME}.ovpn"
    if [[ ! -f "${AWSVPNCLIENT_CONF_DIR}/$VPNCONF" ]]; then
      echo "Error: Configuration file ${AWSVPNCLIENT_CONF_DIR}/$VPNCONF not found"
      return 1
    fi
  else
    # Show dialog to choose connection
    VPNCONF=$(find ${AWSVPNCLIENT_CONF_DIR} -type f -name "*.ovpn" -exec basename {} \; | sort | yad --separator='' --mouse --width=330 --height=250 --skip-taskbar --image=network-vpn --title "AWS Client VPN" --text "Choose a connection" --list --on-top --undecorated --mouse --list --column "select" --no-headers)
    [[ ! -f "${AWSVPNCLIENT_CONF_DIR}/$VPNCONF" ]] && return 1
  fi

  # Extract connection name from config file
  VPN_NAME=${VPNCONF%%.*}
  
  # Check if this connection is already active
  if [ -f "${RUN_DIR}/openvpn-${VPN_NAME}.pid" ]; then
    OPENVPN_PID=$(cat ${RUN_DIR}/openvpn-${VPN_NAME}.pid)
    if ps h -p $OPENVPN_PID -o comm 2>/dev/null | grep -q openvpn; then
      yad --error \
        --title "Connection Already Active" \
        --text "Connection '${VPN_NAME}' is already established" \
        --window-icon=yast-security \
        --skip-taskbar --button "Exit:0"
      return 1
    fi
  fi

  # Copy and edit VPN configuration file with connection-specific naming
  cp ${AWSVPNCLIENT_CONF_DIR}/$VPNCONF ${RUN_DIR}/vpn-${VPN_NAME}.conf
  sed -i '/^auth-user-pass.*$/d' ${RUN_DIR}/vpn-${VPN_NAME}.conf
  sed -i '/^auth-federate.*$/d' ${RUN_DIR}/vpn-${VPN_NAME}.conf
  sed -i '/^auth-retry.*$/d' ${RUN_DIR}/vpn-${VPN_NAME}.conf
  echo "" >> ${RUN_DIR}/vpn-${VPN_NAME}.conf
  echo "script-security 2" >> ${RUN_DIR}/vpn-${VPN_NAME}.conf
  echo "up /opt/openvpn-aws/update-resolv-conf" >> ${RUN_DIR}/vpn-${VPN_NAME}.conf
  echo "down /opt/openvpn-aws/update-resolv-conf" >> ${RUN_DIR}/vpn-${VPN_NAME}.conf

  # Parsing VPN endpoint and picking a single IP address to connect to
  VPN_HOST=$(awk '/^remote / {print $2}' ${RUN_DIR}/vpn-${VPN_NAME}.conf)
  VPN_PORT=$(awk '/^remote / {print $3}' ${RUN_DIR}/vpn-${VPN_NAME}.conf)
  VPN_PROTO=$(awk '/^proto / {print $2}' ${RUN_DIR}/vpn-${VPN_NAME}.conf)
  VPN_SRV=$(dig a +short "${RANDOM}.${VPN_HOST}"|head -n1)
  
  # Stripping remote DNS records from conf
  sed -i '/^remote .*$/d' ${RUN_DIR}/vpn-${VPN_NAME}.conf
  sed -i '/^remote-random-hostname.*$/d' ${RUN_DIR}/vpn-${VPN_NAME}.conf
}

update_current_connection() {
  echo ${VPN_NAME} > ${RUN_DIR}/current_connection-${VPN_NAME}.txt
}

connect() {
  OVPN_OUT=$(/opt/openvpn-aws/openvpn --config ${RUN_DIR}/vpn.conf --verb 3 \
     --proto "$VPN_PROTO" --remote "${VPN_SRV}" "${VPN_PORT}" \
     --auth-user-pass <( printf "%s\n%s\n" "N/A" "ACS::35001" ) \
    2>&1 | grep AUTH_FAILED,CRV1)

  VPN_SID=$(echo "$OVPN_OUT" | awk -F : '{print $7}')
  SSO_URL=$(echo "$OVPN_OUT" | grep -Eo 'https://.+')

  # Start localhost server to capture SAML response and open SSO url
  [[ -f ${RUN_DIR}/server.pid ]] && pkill -F ${RUN_DIR}/server.pid
  cd ${RUN_DIR}
  /opt/openvpn-aws/server &
  echo $! > ${RUN_DIR}/server.pid
  xdg-open $SSO_URL

  # Allow 60s to authenticate
  while [ 1 ]; do
    if [ -f "${RUN_DIR}/saml-response.txt" ]; then
      pkill -F ${RUN_DIR}/server.pid
      break
    else
      TIMER=$((TIMER+1))
    fi
    if [ $TIMER -eq 60 ]; then
      echo "SAML Authentication timed out after 20 seconds"
      return 1
    else
      sleep 1
    fi
  done

  # Convert saml-response.txt to auth-user-pass
  printf "%s\n%s\n" "N/A" "CRV1::${VPN_SID}::$(cat ${RUN_DIR}/saml-response.txt)" > ${RUN_DIR}/auth-user-pass

  # Start the VPN
  sudo /opt/openvpn-aws/openvpn --config ${RUN_DIR}/vpn.conf \
  --verb 3 --auth-nocache --inactive 3600 \
  --proto "$VPN_PROTO" --remote "$VPN_SRV" "$VPN_PORT" \
  --script-security 2 \
  --keepalive 10 60 \
  --auth-user-pass ${RUN_DIR}/auth-user-pass \
  --writepid ${RUN_DIR}/openvpn.pid \
  --daemon openvpn
}

cleanup() {
  for file in saml-response.txt auth-user-pass; do
    if [ -f ${RUN_DIR}/$file ]; then
      rm -f ${RUN_DIR}/$file
    fi
  done
}

check() {
  while [ 1 ]; do
    grep -q "^connected" ${RUN_DIR}/status && break
    SLEEP=$((SLEEP + 1))
    sleep 1
    if [ $SLEEP -gt 30 ]; then
      echo "failed" > ${RUN_DIR}/status
      return 1
    fi
  done
  return 0
}

#MAIN
if [ -f ${RUN_DIR}/openvpn.pid ]; then
  OPENVPN_PID=$(cat ${RUN_DIR}/openvpn.pid)
  ps h -p $OPENVPN_PID -o comm | grep -q openvpn
  if [ $? -eq 0 ]; then
    ls /sys/class/net | grep -q tun
    if [ $? -eq 1 ]; then
      yad --error \
        --title "Notice" \
        --text "OpenVPN is running, but the connection may have terminated. Killing OpenVPN..." \
        --window-icon=yast-security \
        --skip-taskbar --button "Continue:0"
      sudo /opt/openvpn-aws/stop.sh
    else
      yad --error \
        --title "Oops!" \
        --text "A VPN connection is already established" \
        --window-icon=yast-security \
        --skip-taskbar --button "Exit:0"
      exit
    fi
  fi
fi

echo "connecting" > ${RUN_DIR}/status
cleanup
get_conf || exit
update_current_connection
while [ 1 ]; do
  TRIES=$((TRIES + 1))
  connect
  check && break
  if [ $TRIES -gt 3 ]; then break; fi
  pkill -F ${RUN_DIR}/server.pid
done
cleanup


