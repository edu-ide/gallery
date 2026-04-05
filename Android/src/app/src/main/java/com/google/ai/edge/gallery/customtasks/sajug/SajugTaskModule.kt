package com.google.ai.edge.gallery.customtasks.sajug

import com.google.ai.edge.gallery.customtasks.common.CustomTask
import com.google.ai.edge.gallery.data.DataStoreRepository
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoSet

@Module
@InstallIn(SingletonComponent::class)
internal object SajugTaskModule {
  @Provides
  @IntoSet
  fun provideTask(dataStoreRepository: DataStoreRepository): CustomTask {
    return SajugTask(dataStoreRepository)
  }
}
