cd /home/administrator/organized_projects/denon/denon_release_candidate_run

export DENON_IP=192.168.1.162

echo "== Offline static field catalog =="
./denon_release_candidate.sh data fields --all

echo
echo "== Live fields currently available =="
./denon_release_candidate.sh data fields --available

echo
echo "== Live readable data snapshot =="
./denon_release_candidate.sh data dump --readable

echo
echo "== Live JSON data snapshot =="
./denon_release_candidate.sh data dump --json | jq .

echo
echo "== Live raw XML / web response summary =="
./denon_release_candidate.sh data dump --raw

echo
echo "== Live discovery report =="
./denon_release_candidate.sh data discover

echo
echo "== Live discovery report as JSON =="
./denon_release_candidate.sh data discover --json | jq .
