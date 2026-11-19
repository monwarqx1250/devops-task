// k6 load test.
//   k6 run k6.js                                   # normal traffic against the local app
//   k6 run -e ERROR_RATIO=0.2 k6.js                # ~20% calls to /simulate/error (needs FAULT_INJECTION=true)
//   k6 run -e BASE_URL=http://devops-task.localhost:8081 k6.js   # through the k8s Ingress
import { check, sleep } from 'k6';
import http from 'k6/http';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const ERROR_RATIO = Number(__ENV.ERROR_RATIO || 0);

export const options = {
  vus: Number(__ENV.VUS || 10),
  duration: __ENV.DURATION || '30s',
  thresholds: {
    // Fails the run if normal traffic gets slow or starts failing.
    'http_req_duration{expected:yes}': ['p(95)<250'],
    'checks{expected:yes}': ['rate>0.99']
  }
};

export default function () {
  if (Math.random() < ERROR_RATIO) {
    http.get(`${BASE_URL}/simulate/error`, { tags: { expected: 'no' } });
  } else {
    const res = http.get(`${BASE_URL}/`, { tags: { expected: 'yes' } });
    check(res, { 'status is 200': (r) => r.status === 200 }, { expected: 'yes' });
  }
  sleep(0.2);
}
