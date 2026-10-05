# End-to-end demonstration of the order saga through the API gateway.
#   powershell -ExecutionPolicy Bypass -File scripts\demo.ps1
# Scenarios: 1) happy path to DELIVERED  2) declined card -> CANCELLED
#            3) customer cancellation -> refund compensation
param([string]$Gateway = "http://localhost:8080")

$ErrorActionPreference = "Stop"
function Api($Method, $Path, $Body = $null) {
    $params = @{ Method = $Method; Uri = "$Gateway$Path"; ContentType = "application/json" }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 6) }
    Invoke-RestMethod @params
}
function Title($Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

Title "Waiting for the platform"
$services = "customer", "restaurant", "order", "payment", "delivery", "notification", "admin"
foreach ($s in $services) {
    for ($i = 0; $i -lt 90; $i++) {
        try { $h = Api GET "/api/$s-service/health"; if ($h.status -eq "UP") { break } } catch { }
        Start-Sleep 2
    }
    Write-Host ("  {0,-22} {1}" -f "$s-service", $h.status)
}

Title "Catalogue"
$restaurants = Api GET "/api/restaurant-service/restaurants"
$restaurants | ForEach-Object { Write-Host ("  {0}  {1,-24} open={2}" -f $_.restaurantId, $_.name, $_.isOpenNow) }
$menu = Api GET "/api/restaurant-service/restaurants/R-1002/menu"
$pizza = $menu | Where-Object name -eq "Margherita"
$bread = $menu | Where-Object name -eq "Garlic Bread"
Write-Host "  Margherita stock before: $($pizza.stock)"

Title "Surge pricing quote"
$quote = Api GET "/api/order-service/pricing/quote?restaurantId=R-1002&lat=-22.5662&lon=17.1050"
Write-Host "  distance=$($quote.estimatedDistanceKm) km  fee=N`$$($quote.deliveryFee)  surge=x$($quote.surgeMultiplier) ($($quote.surgeLevel))"

function WatchOrder($OrderId, $Until) {
    $last = ""
    for ($i = 0; $i -lt 180; $i++) {
        $o = Api GET "/api/order-service/orders/$OrderId"
        if ($o.status -ne $last) {
            $extra = if ($o.driverName) { " driver=$($o.driverName)" } else { "" }
            Write-Host ("  {0:HH:mm:ss}  {1,-17}{2}" -f (Get-Date), $o.status, $extra)
            $last = $o.status
        }
        if ($o.status -eq "OUT_FOR_DELIVERY") {
            $d = Api GET "/api/delivery-service/deliveries/order/$OrderId"
            Write-Host ("             driver at {0:N5},{1:N5}  eta {2}s" -f $d.currentLocation.lat, $d.currentLocation.lon, $d.etaSeconds) -ForegroundColor DarkGray
        }
        if ($Until -contains $o.status) { return $o }
        Start-Sleep 2
    }
    throw "order $OrderId did not reach $Until"
}

Title "Scenario 1 - happy path (CREATED -> ... -> DELIVERED)"
$order = Api POST "/api/order-service/orders" @{
    customerId = "C-3001"; restaurantId = "R-1002"; paymentMethod = "CARD"; cardLast4 = "4242"
    items = @(@{ itemId = $pizza.itemId; quantity = 2 }, @{ itemId = $bread.itemId; quantity = 1 })
}
Write-Host "  placed $($order.orderId) total=N`$$($order.total) (fee N`$$($order.deliveryFee), surge x$($order.surgeMultiplier))"
$final = WatchOrder $order.orderId @("DELIVERED", "CANCELLED")
$final.statusHistory | ForEach-Object { Write-Host ("    {0,-17} by {1,-18} {2}" -f $_.status, $_.actor, $_.reason) -ForegroundColor DarkGray }
$pay = Api GET "/api/payment-service/payments/order/$($order.orderId)"
Write-Host "  payment $($pay.paymentId) $($pay.status) ref=$($pay.transactionRef)"
$pizzaAfter = (Api GET "/api/restaurant-service/restaurants/R-1002/menu") | Where-Object name -eq "Margherita"
Write-Host "  Margherita stock after: $($pizzaAfter.stock) (inventory reserved by the kitchen)"

Title "Scenario 2 - declined card (saga compensation)"
$bad = Api POST "/api/order-service/orders" @{
    customerId = "C-3002"; restaurantId = "R-1003"; paymentMethod = "CARD"; cardLast4 = "0000"
    items = @(@{ itemId = "M-109"; quantity = 1 })
}
$badFinal = WatchOrder $bad.orderId @("CANCELLED", "DELIVERED")
Write-Host "  reason: $($badFinal.cancelReason)"

Title "Scenario 3 - customer cancels after paying (refund)"
$c = Api POST "/api/order-service/orders" @{
    customerId = "C-3003"; restaurantId = "R-1004"; paymentMethod = "MOBILE_MONEY"
    items = @(@{ itemId = "M-114"; quantity = 1 })
}
# wait (briefly) until the payment confirmed the order - the kitchen starts cooking 5s later
for ($i = 0; $i -lt 40; $i++) {
    if ((Api GET "/api/order-service/orders/$($c.orderId)").status -ne "CREATED") { break }
    Start-Sleep -Milliseconds 250
}
$cancelled = Api PUT "/api/order-service/orders/$($c.orderId)/cancel" @{ reason = "Ordered by mistake" }
Write-Host "  $($cancelled.orderId) -> $($cancelled.status)"
Start-Sleep 4
$refund = Api GET "/api/payment-service/payments/order/$($c.orderId)"
Write-Host "  payment status: $($refund.status)  ($($refund.failureReason))"

Title "Notifications for C-3001"
(Api GET "/api/notification-service/notifications?recipientType=CUSTOMER&recipientId=C-3001&limit=8") |
    ForEach-Object { Write-Host ("  [{0,-5}] {1}: {2}" -f $_.channel, $_.title, $_.body) }

Title "Admin reports"
$o = Api GET "/api/admin-service/reports/overview"
Write-Host "  orders=$($o.totalOrders) delivered=$($o.delivered) cancelled=$($o.cancelled) GMV=N`$$($o.grossMerchandiseValue) avgFulfilment=$($o.avgFulfilmentMinutes)min onTime=$($o.onTimeRate)"
(Api GET "/api/admin-service/reports/events") | ForEach-Object { Write-Host ("  {0,-28} {1}" -f $_.topic, $_.count) }
Write-Host "`nDone. Open http://localhost:8080 for the UI." -ForegroundColor Green
