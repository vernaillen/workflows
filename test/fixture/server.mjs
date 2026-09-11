// Fixture server for the self-test. Answers /healthz so the pipeline's boot
// probe has something to hit, and nothing else.
import { createServer } from 'node:http'

const port = Number(process.env.PORT ?? 3000)

createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'text/plain' })
    res.end('ok\n')
    return
  }
  res.writeHead(404)
  res.end()
}).listen(port, () => {
  console.log(`fixture listening on :${port}`)
})
