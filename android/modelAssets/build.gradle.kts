plugins {
    id("com.android.asset-pack")
}

assetPack {
    packName.set("modelAssets")
    dynamicDelivery {
        deliveryType.set("install-time")
    }
}
