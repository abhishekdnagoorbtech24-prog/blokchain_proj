import json,os
b=lambda n:json.load(open(f"build/{n}.json"))
art={n:b(n) for n in ["MockStable","MockFeed","StablePaySettlement"]}
t=open("dapp/app.template.html").read()
t=t.replace("/*ETHERS*/",open("node_modules/ethers/dist/ethers.umd.min.js").read())
t=t.replace("/*GANACHE*/",open("node_modules/ganache/dist/web/ganache.min.js").read().replace("</script>","<\\/script>"))
t=t.replace("/*ARTIFACTS*/",json.dumps(art))
open("dapp/StablePay_DApp.html","w").write(t);print(os.path.getsize("dapp/StablePay_DApp.html")/1e6,"MB")
