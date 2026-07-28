HOST ?= synas.local

.PHONY: check deploy run

check:
	bash -n hibdbg.sh

deploy: check
	scp -O hibdbg.sh $(HOST):hibdbg.sh.new
	ssh $(HOST) 'mv hibdbg.sh.new hibdbg.sh && chmod +x hibdbg.sh'

# make run CMD="live 10" -- runs on the box (sudo prompts for password)
run:
	ssh -t $(HOST) "sudo ./hibdbg.sh $(CMD)"
